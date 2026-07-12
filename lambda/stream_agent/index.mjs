// Streaming reflection loop — runs generator/evaluator directly via Bedrock.
// Deployed as a Lambda Function URL with invoke_mode = RESPONSE_STREAM.
// Uses @aws/aws-jwt-verify (bundled) for Cognito JWT validation.
// AWS SDK v3 is provided by the Node.js 22 Lambda runtime (not bundled here).

import { DynamoDBClient, GetItemCommand, UpdateItemCommand } from '@aws-sdk/client-dynamodb';
import { unmarshall } from '@aws-sdk/util-dynamodb';
import {
  BedrockRuntimeClient,
  InvokeModelWithResponseStreamCommand,
  InvokeModelCommand,
} from '@aws-sdk/client-bedrock-runtime';
import { CognitoJwtVerifier } from 'aws-jwt-verify';

const REGION       = process.env.REGION            ?? 'us-east-1';
const TABLE_NAME   = process.env.DYNAMODB_TABLE;
const MODEL_ID     = process.env.BEDROCK_MODEL_ID  ?? 'us.anthropic.claude-haiku-4-5-20251001-v1:0';
const USER_POOL_ID = process.env.USER_POOL_ID;

const UNLIMITED       = -1;
const MAX_ROUNDS      = 5;
const SCORE_THRESHOLD = 4;

const ddb     = new DynamoDBClient({ region: REGION });
const bedrock = new BedrockRuntimeClient({ region: REGION });

// clientId: null skips aud-claim validation (no COGNITO_CLIENT_ID needed,
// which would otherwise create a Terraform dependency cycle via CloudFront).
// Issuer, signature, expiry, and the DynamoDB quota check still gate access.
const verifier = CognitoJwtVerifier.create({
  userPoolId: USER_POOL_ID,
  tokenUse:   'id',
  clientId:   null,
});

// ── Prompts ───────────────────────────────────────────────────────────────────

const GENERATOR_SYSTEM = `\
You are a cybersecurity assistant that maps cybersecurity issues to NIST 800-53 \
security and privacy controls. When given a cybersecurity issue, immediately respond \
with the most relevant controls. Do not ask clarifying questions. For each control \
provide the control ID, name, and a brief explanation of why it applies. \
If given evaluator feedback from a previous round, incorporate it to improve your mapping.`;

const EVALUATOR_SYSTEM = `\
You are an expert evaluator of NIST 800-53 control mappings. \
Given a cybersecurity issue and a proposed set of controls, score the mapping:
  1 = Poor, 2 = Fair, 3 = Good, 4 = Very Good, 5 = Excellent
Reply in exactly this format:
SCORE: <1-5>
FEEDBACK: <specific feedback>`;

// ── SSE helper ────────────────────────────────────────────────────────────────

function sse(data) {
  return `data: ${JSON.stringify(data)}\n\n`;
}

// ── DynamoDB quota ────────────────────────────────────────────────────────────

async function checkAndDecrement(email) {
  const result = await ddb.send(new GetItemCommand({
    TableName: TABLE_NAME,
    Key: { email: { S: email } },
  }));
  if (!result.Item) return { allowed: false, error: 'Access denied' };

  const { calls_remaining } = unmarshall(result.Item);
  const remaining = Number(calls_remaining);
  if (remaining === UNLIMITED) return { allowed: true };
  if (remaining <= 0) return { allowed: false, error: 'Call limit reached (5/5 used)' };

  try {
    await ddb.send(new UpdateItemCommand({
      TableName: TABLE_NAME,
      Key: { email: { S: email } },
      UpdateExpression: 'SET calls_remaining = calls_remaining - :one',
      ConditionExpression: 'calls_remaining > :zero',
      ExpressionAttributeValues: { ':one': { N: '1' }, ':zero': { N: '0' } },
    }));
    return { allowed: true };
  } catch (e) {
    if (e.name === 'ConditionalCheckFailedException') {
      return { allowed: false, error: 'Call limit reached' };
    }
    throw e;
  }
}

// ── Bedrock calls ─────────────────────────────────────────────────────────────

async function invokeStreaming(system, userPrompt, onToken) {
  const response = await bedrock.send(new InvokeModelWithResponseStreamCommand({
    modelId:     MODEL_ID,
    contentType: 'application/json',
    body: JSON.stringify({
      anthropic_version: 'bedrock-2023-05-31',
      max_tokens: 2048,
      system,
      messages: [{ role: 'user', content: userPrompt }],
    }),
  }));

  let fullText = '';
  for await (const event of response.body) {
    if (event.chunk?.bytes) {
      const chunk = JSON.parse(Buffer.from(event.chunk.bytes).toString('utf-8'));
      if (chunk.type === 'content_block_delta' && chunk.delta?.type === 'text_delta') {
        const token = chunk.delta.text;
        fullText += token;
        onToken(token);
      }
    }
  }
  return fullText;
}

async function invokeDirect(system, userPrompt) {
  const response = await bedrock.send(new InvokeModelCommand({
    modelId:     MODEL_ID,
    contentType: 'application/json',
    body: JSON.stringify({
      anthropic_version: 'bedrock-2023-05-31',
      max_tokens: 512,
      system,
      messages: [{ role: 'user', content: userPrompt }],
    }),
  }));
  return JSON.parse(Buffer.from(response.body).toString('utf-8')).content[0].text;
}

// ── Handler ───────────────────────────────────────────────────────────────────

export const handler = awslambda.streamifyResponse(async (event, responseStream) => {
  const httpStream = awslambda.HttpResponseStream.from(responseStream, {
    statusCode: 200,
    headers: {
      'Content-Type':    'text/event-stream; charset=utf-8',
      'Cache-Control':   'no-cache, no-transform',
      'X-Accel-Buffering': 'no',
    },
  });

  try {
    // ── Parse body first (token lives in the body to avoid OAC signing issues) ─
    // CloudFront OAC signs every forwarded header; any in-flight normalisation
    // of a custom header (X-User-Token) causes InvalidSignatureException.
    // Putting the JWT in the POST body keeps the signed-header set minimal.
    let inputText = '';
    let token = '';
    try {
      const parsed = JSON.parse(event.body ?? '{}');
      inputText = (parsed.inputText ?? '').trim();
      token = (parsed.token ?? '').replace(/^Bearer\s+/i, '');
    } catch {
      httpStream.write(sse({ type: 'error', message: 'Invalid request body' }));
      return;
    }
    if (!inputText) {
      httpStream.write(sse({ type: 'error', message: 'inputText is required' }));
      return;
    }
    if (!token) {
      httpStream.write(sse({ type: 'error', message: 'Unauthorized', code: 'UNAUTHORIZED' }));
      return;
    }

    // ── Auth ──────────────────────────────────────────────────────────────────
    let claims;
    try {
      claims = await verifier.verify(token);
    } catch {
      httpStream.write(sse({ type: 'error', message: 'Unauthorized', code: 'UNAUTHORIZED' }));
      return;
    }

    // ── Quota ─────────────────────────────────────────────────────────────────
    const { allowed, error: quotaError } = await checkAndDecrement(claims.email);
    if (!allowed) {
      httpStream.write(sse({ type: 'error', message: quotaError, code: 'QUOTA_EXCEEDED' }));
      return;
    }

    // ── Reflection loop ───────────────────────────────────────────────────────
    let mapping  = '';
    let score    = 0;
    let feedback = null;
    let roundNum = 0;

    for (let round = 1; round <= MAX_ROUNDS; round++) {
      roundNum = round;
      httpStream.write(sse({ type: 'round_start', round, total: MAX_ROUNDS }));

      const genPrompt = feedback
        ? `Cybersecurity issue: ${inputText}\n\nPrevious mapping:\n${mapping}\n\nEvaluator feedback:\n${feedback}\n\nImprove your NIST 800-53 mapping.`
        : `Cybersecurity issue: ${inputText}`;

      mapping = await invokeStreaming(GENERATOR_SYSTEM, genPrompt, t =>
        httpStream.write(sse({ type: 'token', content: t }))
      );

      const evalResponse = await invokeDirect(
        EVALUATOR_SYSTEM,
        `Cybersecurity issue: ${inputText}\n\nProposed NIST 800-53 mapping:\n${mapping}`,
      );

      const scoreMatch    = evalResponse.match(/SCORE:\s*([1-5])/);
      score               = scoreMatch ? parseInt(scoreMatch[1], 10) : 0;
      const feedbackMatch = evalResponse.match(/FEEDBACK:\s*(.+)/s);
      feedback            = feedbackMatch ? feedbackMatch[1].trim() : evalResponse.trim();

      httpStream.write(sse({ type: 'round_end', round, score, passed: score >= SCORE_THRESHOLD }));
      if (score >= SCORE_THRESHOLD) break;
    }

    httpStream.write(sse({ type: 'done', score, rounds: roundNum }));

  } catch (err) {
    console.error('Stream handler error:', err);
    try {
      httpStream.write(sse({ type: 'error', message: err.message ?? 'Internal error' }));
    } catch { /* stream already ended */ }
  } finally {
    httpStream.end();
  }
});
