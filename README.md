# Jenkins → AWS DevOps Agent Integration

Automatically start an [AWS DevOps Agent](https://aws.amazon.com/devops-agent/)
investigation whenever a Jenkins build fails. Jenkins sends the build details
(job, stage, branch, last log lines, target environment) to a small Lambda
forwarder, which hands them to your Agent Space as an incident.

> **Disclaimer:** This is sample code, not intended for production use without
> additional review and testing. Validate it in a non-production environment
> first and adapt the IAM, logging, and retention settings to your own standards.

## How it works

```
Jenkins build FAILS
   │  post { failure { ... } }  — SigV4-signed HTTPS POST (Jenkins' own IAM role)
   ▼
Lambda Function URL  (AuthType: AWS_IAM — only the Jenkins principal may call it)
   │  validates + bounds the input, maps it to the DevOps Agent incident schema,
   │  HMAC-signs it with the webhook secret from Secrets Manager
   ▼
AWS DevOps Agent webhook  →  investigation starts in your Agent Space
```

Why a forwarder instead of calling the webhook straight from Jenkins:

- **The webhook signing secret stays in AWS.** Jenkins never holds it; it only
  needs IAM credentials it usually already has.
- **No shared tokens.** The endpoint is authenticated by IAM (SigV4), the same way
  Jenkins calls any other AWS API.
- **One place to shape the payload.** Every pipeline sends simple build fields; the
  Lambda turns them into the incident schema the agent expects.

If you'd rather not run a Lambda, see [Alternative: call the webhook directly](#alternative-call-the-webhook-directly).

## What's in this repo

| File | Purpose |
|------|---------|
| `template.yaml` | CloudFormation stack: Lambda forwarder, IAM-authenticated Function URL, Secrets Manager secret, IAM role |
| `examples/Jenkinsfile` | Declarative pipeline showing the failure-notification `post` block |
| `examples/send-test-event.sh` | Send a signed test event from your laptop, no Jenkins needed |
| `examples/sample-payload.json` | Example build-failure payload |

## Prerequisites

- An AWS DevOps Agent **Agent Space** connected to the AWS account(s) Jenkins
  deploys to, so the agent can inspect those resources during the investigation.
- A **webhook** on that Agent Space (step 1). You need its URL and signing secret.
- The **IAM role Jenkins runs as**: an EC2 instance profile, an EKS IRSA / Pod
  Identity role, or the role used by the AWS Credentials plugin. You pass its ARN at
  deploy time.
- On the Jenkins agent: **AWS CLI v2 (2.9 or newer)** and **curl 7.75 or newer**
  (for `--aws-sigv4`).
- Permission to deploy CloudFormation stacks with IAM resources.

## Setup

### 1. Create a webhook in your Agent Space

In the AWS DevOps Agent console, open your Agent Space and add a **generic webhook**
integration. Copy the **webhook URL** and **signing secret**. You'll load them into
Secrets Manager in step 3; don't put them in Jenkins.

### 2. Deploy the forwarder stack

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name jenkins-devops-agent \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    JenkinsPrincipalArn=arn:aws:iam::111122223333:role/example-jenkins-agent-role
```

Read the outputs:

```bash
aws cloudformation describe-stacks --stack-name jenkins-devops-agent \
  --query 'Stacks[0].Outputs' --output table
```

- `ForwarderEndpoint`: the URL Jenkins will POST to
- `WebhookSecretArn`: where the webhook credentials go
- `FunctionName`: the Lambda, so you can find its logs

The template sets no fixed resource names, so you can deploy it more than once (for
example, one stack per environment) without name collisions.

### 3. Load the webhook credentials

The stack creates the secret with placeholder values, and the forwarder refuses to
send anything until you replace them. Load the real values without leaving them in
your shell history:

```bash
SECRET_ARN=$(aws cloudformation describe-stacks --stack-name jenkins-devops-agent \
  --query "Stacks[0].Outputs[?OutputKey=='WebhookSecretArn'].OutputValue" --output text)

read -r  -p "Webhook URL: " WEBHOOK_URL
read -rs -p "Webhook signing secret: " WEBHOOK_SECRET; echo

umask 077; TMP=$(mktemp)
jq -n --arg u "$WEBHOOK_URL" --arg s "$WEBHOOK_SECRET" \
  '{webhookUrl: $u, webhookSecret: $s}' > "$TMP"
aws secretsmanager put-secret-value --secret-id "$SECRET_ARN" --secret-string "file://$TMP"
rm -f "$TMP"; unset WEBHOOK_SECRET
```

The Lambda caches the secret for up to 5 minutes. After you rotate it, wait that
long or redeploy the function.

### 4. Test without Jenkins

Run this with credentials for the Jenkins principal, for example after assuming that
role:

```bash
./examples/send-test-event.sh "<ForwarderEndpoint>" us-east-1
```

Expected response: `HTTP 200` with an `incidentId`. A new investigation should then
appear in your Agent Space. If you get anything else, see
[Troubleshooting](#troubleshooting).

### 5. Give Jenkins AWS credentials

Use whichever your Jenkins setup already supports. The Jenkinsfile reads credentials
via `aws configure export-credentials`, so any of these work unchanged:

| Jenkins runs on | Credential source | Stored secrets in Jenkins |
|-----------------|-------------------|---------------------------|
| EC2 | Instance profile role | None |
| EKS | IRSA or EKS Pod Identity role | None |
| Anywhere | AWS Credentials plugin (`withAWS` / `AmazonWebServicesCredentialsBinding`) | Access key (prefer roles where possible) |

**Same account:** the stack's resource-based policy is enough, and no extra IAM
policy is needed on the Jenkins role. **Different account:** also attach an identity
policy to the Jenkins role allowing `lambda:InvokeFunctionUrl` and
`lambda:InvokeFunction` on the forwarder function's ARN.

### 6. Add the failure notification to your pipeline

Copy two things from [`examples/Jenkinsfile`](examples/Jenkinsfile) into your
pipeline:

1. **Stage tracking:** a `def failedStage = 'unknown'` above `pipeline { }`, and in
   each stage:
   ```groovy
   post { failure { script { failedStage = env.STAGE_NAME } } }
   ```
2. **The pipeline-level `post { failure { ... } }` block.** It builds the payload
   with `JsonOutput`, so quotes and newlines in logs stay valid JSON, and sends it
   with a SigV4-signed `curl`.

Set `DEVOPS_AGENT_ENDPOINT` to the `ForwarderEndpoint` output. It isn't a secret: the
URL rejects any request that isn't signed by the allowed IAM principal.

To give the agent the actual error, have stages write their output to `stage.log`
(the example uses `set -o pipefail` with `| tee stage.log`). The post block sends the
last 50 lines. This needs no Jenkins script approvals.

Notification is best effort. If the forwarder can't be reached, the post block logs
why and doesn't error.

## Payload fields

Jenkins sends a flat JSON object. Only `jobName` and `buildNumber` really matter.
Everything else adds context for the investigation.

| Field | Description |
|-------|-------------|
| `jobName` | Jenkins job / pipeline name |
| `buildNumber` | Build number |
| `buildUrl` | Link back to the build |
| `status` | Build result (default `FAILURE`) |
| `failedStage` | Stage that failed |
| `branch`, `repository` | Source info |
| `triggeredBy` | Build cause |
| `duration` | Build duration |
| `errorLog` | Last lines of output (truncated to 2,000 characters) |
| `environment` | Target environment, e.g. `prod` / `staging` |
| `awsRegion` | Region of the infrastructure being deployed |
| `priority` | `CRITICAL`, `HIGH`, `MEDIUM`, or `LOW` (default `HIGH`) |
| `context` | Free-form object: cluster, namespace, service, stack name, and so on |

The forwarder caps every field's length and the request body (64 KB), then maps the
fields to the DevOps Agent incident schema: `eventType: "incident"`,
`action: "created"`, a readable `description` (summary plus the error log), build
details under `data.jenkins`, and your `context` under `data.context`. It keeps the
final payload under the webhook's 10,000-character limit: a `context` over 2,000
characters is dropped, and the oldest log lines are trimmed first.

**Tip:** the more specific `context` is (exact cluster, service, stack, or function
names), the faster the agent finds the right resources.

## What the agent does with it

The agent treats the failure as an incident. It reads the error text and context,
inspects the AWS resources involved (for example EKS, ECR, IAM, networking), checks
recent changes and CloudTrail activity, and reports a root cause and suggested
mitigation in the Agent Space.

## Optional: get notified when the investigation finishes

DevOps Agent publishes EventBridge events with source `aws.aidevops` and detail-type
`Investigation Completed` / `Investigation Failed`. Route them to SNS (email,
Slack via Chatbot) or a Lambda to post the findings wherever your team works:

```json
{
  "source": ["aws.aidevops"],
  "detail-type": ["Investigation Completed", "Investigation Failed"]
}
```

## Alternative: call the webhook directly

Jenkins can also HMAC-sign the incident payload and POST it straight to the Agent
Space webhook, with no Lambda involved. That's fewer moving parts, but the webhook
signing secret then has to live in Jenkins credentials, and each pipeline has to
build the full incident schema itself. The signature is
`base64(HMAC-SHA256(secret, "<timestamp>:<body>"))`, sent in the
`x-amzn-event-signature` header, with the same ISO-8601 timestamp (including
milliseconds) in `x-amzn-event-timestamp`. Sign the exact bytes you send.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `HTTP 403` from the Function URL | Request not SigV4-signed, signed for the wrong region/service (must be `lambda`), or signed by a principal other than `JenkinsPrincipalArn`. Cross-account callers also need the identity policy from step 5. |
| `HTTP 500 Forwarder not configured` | The secret still has placeholder values, or the URL isn't `https://` (step 3). |
| `HTTP 502 ... returned 401/403` | Webhook URL or signing secret doesn't match the Agent Space webhook. Reload the secret, then wait for the 5-minute cache. |
| `HTTP 502 ... returned 400` | The webhook rejected the payload. Check the forwarder's CloudWatch logs for the response body. |
| `HTTP 413` | Request body over 64 KB. Send fewer log lines. |
| `curl: option --aws-sigv4: is unknown` | curl older than 7.75 on the Jenkins agent. |
| `export-credentials` not found | AWS CLI older than 2.9. |

Forwarder logs: CloudWatch Logs group `/aws/lambda/<FunctionName>`.

## Cleanup

```bash
aws cloudformation delete-stack --stack-name jenkins-devops-agent
```

Also remove the webhook from the Agent Space if you no longer need it.

## Security notes

- The endpoint is IAM-authenticated. There is no unauthenticated public URL and no
  shared token.
- The webhook signing secret is stored only in Secrets Manager, and only the
  forwarder's role can read it.
- The forwarder never logs the payload or the secret. Logs contain the incident ID,
  status codes, and webhook error responses.
- Build logs can contain sensitive values. Review what your stages write to
  `stage.log` before sending it, and mask secrets in Jenkins output.

## License

This sample is licensed under the MIT-0 License. See [LICENSE](LICENSE).
