const VERIFIER_KEY = 'pkce_verifier'
const TOKEN_KEY = 'id_token'

function base64url(buffer) {
  return btoa(String.fromCharCode(...new Uint8Array(buffer)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '')
}

async function generatePKCE() {
  const verifier = base64url(crypto.getRandomValues(new Uint8Array(32)))
  const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))
  const challenge = base64url(hash)
  return { verifier, challenge }
}

export async function startLogin(config) {
  const { verifier, challenge } = await generatePKCE()
  sessionStorage.setItem(VERIFIER_KEY, verifier)

  const callbackUrl = `${config.cloudFrontUrl}/callback`
  const params = new URLSearchParams({
    response_type: 'code',
    client_id: config.clientId,
    redirect_uri: callbackUrl,
    scope: 'email openid profile',
    code_challenge: challenge,
    code_challenge_method: 'S256',
    identity_provider: 'Google',
  })
  window.location.href = `${config.cognitoDomain}/oauth2/authorize?${params}`
}

export async function handleCallback(config) {
  const params = new URLSearchParams(window.location.search)
  const code = params.get('code')
  if (!code) return false

  const verifier = sessionStorage.getItem(VERIFIER_KEY)
  if (!verifier) return false

  const callbackUrl = `${config.cloudFrontUrl}/callback`
  const body = new URLSearchParams({
    grant_type: 'authorization_code',
    client_id: config.clientId,
    redirect_uri: callbackUrl,
    code,
    code_verifier: verifier,
  })

  const resp = await fetch(`${config.cognitoDomain}/oauth2/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  })

  if (!resp.ok) return false
  const tokens = await resp.json()
  sessionStorage.setItem(TOKEN_KEY, tokens.id_token)
  sessionStorage.removeItem(VERIFIER_KEY)

  // Clean up the URL without triggering a reload
  window.history.replaceState({}, '', window.location.pathname)
  return true
}

export function getToken() {
  return sessionStorage.getItem(TOKEN_KEY)
}

export function logout() {
  sessionStorage.removeItem(TOKEN_KEY)
}
