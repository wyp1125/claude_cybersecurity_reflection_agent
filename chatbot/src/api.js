import { CognitoIdentityClient, GetIdCommand, GetCredentialsForIdentityCommand } from '@aws-sdk/client-cognito-identity'
import { AwsClient } from 'aws4fetch'

export class QuotaError extends Error {
  constructor(message) {
    super(message)
    this.name = 'QuotaError'
  }
}

// ── Cognito Identity credential cache ─────────────────────────────────────────
// Browser exchanges its Cognito ID token for temporary IAM credentials so it
// can SigV4-sign requests directly to the Lambda Function URL. CloudFront OAC
// is NOT used (it signs host:<domain>:443 but Lambda verifies host:<domain>).

let _awsClient = null
let _credExpiry = 0

async function getSignedClient(config, idToken) {
  // Reuse cached client if credentials don't expire within 5 minutes
  if (_awsClient && Date.now() < _credExpiry - 5 * 60 * 1000) {
    return _awsClient
  }

  const identity = new CognitoIdentityClient({ region: config.region })
  const providerKey = `cognito-idp.${config.region}.amazonaws.com/${config.userPoolId}`

  const { IdentityId } = await identity.send(new GetIdCommand({
    IdentityPoolId: config.identityPoolId,
    Logins: { [providerKey]: idToken },
  }))

  const { Credentials } = await identity.send(new GetCredentialsForIdentityCommand({
    IdentityId,
    Logins: { [providerKey]: idToken },
  }))

  _credExpiry = new Date(Credentials.Expiration).getTime()
  _awsClient = new AwsClient({
    accessKeyId:     Credentials.AccessKeyId,
    secretAccessKey: Credentials.SecretKey,
    sessionToken:    Credentials.SessionToken,
    region:          config.region,
    service:         'lambda',
  })
  return _awsClient
}

// ── Streaming agent invocation ────────────────────────────────────────────────

export async function invokeAgentStreaming(streamUrl, idToken, inputText, callbacks = {}, config = null) {
  const body = JSON.stringify({ inputText, token: `Bearer ${idToken}` })

  let resp
  if (config?.identityPoolId) {
    // Sign the request with temporary IAM credentials from Cognito Identity Pool
    const aws = await getSignedClient(config, idToken)
    resp = await aws.fetch(streamUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
    })
  } else {
    resp = await fetch(streamUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
    })
  }

  if (!resp.ok || !resp.body) {
    throw new Error(`HTTP ${resp.status}`)
  }

  const ct = resp.headers.get('content-type') ?? ''
  if (!ct.includes('text/event-stream') && !ct.includes('application/json')) {
    const preview = await resp.text().then(t => t.slice(0, 120))
    throw new Error(`Expected SSE stream but got ${ct || 'unknown content-type'}. Body: ${preview}`)
  }

  const reader  = resp.body.getReader()
  const decoder = new TextDecoder()
  let buffer    = ''

  while (true) {
    const { done, value } = await reader.read()
    if (done) break

    buffer += decoder.decode(value, { stream: true })

    const lines = buffer.split('\n')
    buffer = lines.pop()

    for (const line of lines) {
      if (!line.startsWith('data: ')) continue
      let event
      try { event = JSON.parse(line.slice(6)) } catch { continue }

      switch (event.type) {
        case 'round_start': callbacks.onRoundStart?.(event.round, event.total); break
        case 'token':       callbacks.onToken?.(event.content);                 break
        case 'round_end':   callbacks.onRoundEnd?.(event.round, event.score, event.passed); break
        case 'done':        callbacks.onDone?.(event.score, event.rounds);      break
        case 'error':
          if (event.code === 'QUOTA_EXCEEDED') throw new QuotaError(event.message)
          throw new Error(event.message || 'Stream error')
      }
    }
  }
}
