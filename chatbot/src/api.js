export class QuotaError extends Error {
  constructor(message) {
    super(message)
    this.name = 'QuotaError'
  }
}

// Non-streaming fallback (kept for reference, not used by the chatbot UI)
export async function invokeAgent(apiUrl, idToken, inputText) {
  const resp = await fetch(apiUrl, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${idToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ inputText }),
  })
  if (resp.status === 429) {
    const data = await resp.json().catch(() => ({}))
    throw new QuotaError(data.error || 'Call limit reached')
  }
  if (!resp.ok) {
    const data = await resp.json().catch(() => ({}))
    throw new Error(data.error || `HTTP ${resp.status}`)
  }
  return resp.json()
}

/**
 * Invoke the streaming agent via Lambda Function URL.
 *
 * SSE events emitted by the Lambda:
 *   { type: 'round_start', round, total }
 *   { type: 'token',       content }
 *   { type: 'round_end',   round, score, passed }
 *   { type: 'done',        score, rounds }
 *   { type: 'error',       message, code? }
 *
 * @param {string}   streamUrl - Lambda Function URL
 * @param {string}   idToken   - Cognito id_token
 * @param {string}   inputText
 * @param {object}   callbacks - { onRoundStart, onToken, onRoundEnd, onDone, onError }
 */
export async function invokeAgentStreaming(streamUrl, idToken, inputText, callbacks = {}) {
  const resp = await fetch(streamUrl, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${idToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ inputText }),
  })

  if (!resp.ok || !resp.body) {
    throw new Error(`HTTP ${resp.status}`)
  }

  const reader  = resp.body.getReader()
  const decoder = new TextDecoder()
  let buffer    = ''

  while (true) {
    const { done, value } = await reader.read()
    if (done) break

    buffer += decoder.decode(value, { stream: true })

    // SSE lines end with \n; events are separated by \n\n
    const lines = buffer.split('\n')
    buffer = lines.pop() // hold back incomplete last line

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
