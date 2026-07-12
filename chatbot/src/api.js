import { CognitoIdentityClient, GetIdCommand, GetOpenIdTokenCommand } from '@aws-sdk/client-cognito-identity'
import { STSClient, AssumeRoleWithWebIdentityCommand } from '@aws-sdk/client-sts'
import { SignatureV4 } from '@smithy/signature-v4'
import { Sha256 } from '@aws-crypto/sha256-browser'

export class QuotaError extends Error {
  constructor(message) {
    super(message)
    this.name = 'QuotaError'
  }
}

// ── Cognito Identity credential cache ─────────────────────────────────────────

let _creds = null
let _credExpiry = 0

async function getCognitoCredentials(config, idToken) {
  if (_creds && Date.now() < _credExpiry - 5 * 60 * 1000) return _creds

  const identity = new CognitoIdentityClient({ region: config.region })
  const providerKey = `cognito-idp.${config.region}.amazonaws.com/${config.userPoolId}`

  const { IdentityId } = await identity.send(new GetIdCommand({
    IdentityPoolId: config.identityPoolId,
    Logins: { [providerKey]: idToken },
  }))

  // Basic flow: GetOpenIdToken → AssumeRoleWithWebIdentity.
  // The enhanced flow (GetCredentialsForIdentity) injects a Cognito-managed
  // session policy that silently blocks lambda:InvokeFunctionUrl at runtime
  // even though the role policy and IAM simulator both show ALLOW.
  const { Token } = await identity.send(new GetOpenIdTokenCommand({
    IdentityId,
    Logins: { [providerKey]: idToken },
  }))

  const sts = new STSClient({ region: config.region })
  const { Credentials } = await sts.send(new AssumeRoleWithWebIdentityCommand({
    RoleArn:          config.cognitoRoleArn,
    RoleSessionName:  'ChatSession',
    WebIdentityToken: Token,
    DurationSeconds:  3600,
  }))

  _credExpiry = new Date(Credentials.Expiration).getTime()
  _creds = {
    accessKeyId:     Credentials.AccessKeyId,
    secretAccessKey: Credentials.SecretAccessKey,
    sessionToken:    Credentials.SessionToken,
  }
  return _creds
}

// ── SigV4-signed fetch using @smithy/signature-v4 ────────────────────────────
// Uses the same signing engine as the AWS SDK v3, avoiding subtle differences
// in body-hash computation that can cause InvalidSignatureException with Lambda
// Function URLs (AuthType = AWS_IAM).

async function signedFetch(url, body, creds, region) {
  const { hostname, pathname } = new URL(url)

  const signer = new SignatureV4({
    credentials: creds,
    region,
    service: 'lambda',
    sha256: Sha256,
  })

  const signed = await signer.sign({
    method:   'POST',
    protocol: 'https:',
    hostname,
    path:     pathname || '/',
    headers: {
      'content-type': 'application/json',
      host:            hostname,
    },
    body,
  })

  // Browsers forbid setting the 'host' header; strip it — the browser sends
  // the correct value automatically for the URL we're fetching.
  const { host: _host, ...fetchHeaders } = signed.headers

  return fetch(url, { method: 'POST', headers: fetchHeaders, body })
}

// ── Streaming agent invocation ────────────────────────────────────────────────

export async function invokeAgentStreaming(streamUrl, idToken, inputText, callbacks = {}, config = null) {
  const body = JSON.stringify({ inputText, token: `Bearer ${idToken}` })

  let resp
  if (config?.identityPoolId) {
    console.log('[stream] getting Cognito Identity credentials...')
    const creds = await getCognitoCredentials(config, idToken)
    console.log('[stream] credentials obtained, sending signed request to', streamUrl)
    resp = await signedFetch(streamUrl, body, creds, config.region)
    console.log('[stream] response status:', resp.status)
  } else {
    resp = await fetch(streamUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
    })
  }

  if (!resp.ok) {
    const errType = resp.headers.get('x-amzn-ErrorType') ?? ''
    const errBody = await resp.text().catch(() => '')
    throw new Error(`HTTP ${resp.status}${errType ? ' ' + errType : ''}${errBody ? ': ' + errBody.slice(0, 200) : ''}`)
  }
  if (!resp.body) {
    throw new Error(`HTTP ${resp.status}: no response body`)
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
