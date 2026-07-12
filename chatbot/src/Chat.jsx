import { useRef, useEffect, useState } from 'react'
import { invokeAgentStreaming, QuotaError } from './api.js'
import { logout } from './auth.js'

const SCORE_THRESHOLD = 4

export default function Chat({ config, token, onLogout }) {
  const [messages, setMessages] = useState([{
    role: 'assistant',
    content: "Hello! Describe a cybersecurity issue and I'll map it to the relevant NIST 800-53 controls.",
  }])
  const [input, setInput]               = useState('')
  const [loading, setLoading]           = useState(false)
  const [roundStatus, setRoundStatus]   = useState(null)   // e.g. "Round 2/5: Improving…"
  const [quotaExhausted, setQuotaExhausted] = useState(false)
  const bottomRef = useRef(null)

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages, roundStatus])

  async function handleSubmit(e) {
    e.preventDefault()
    const text = input.trim()
    if (!text || loading || quotaExhausted) return

    setInput('')
    setMessages(prev => [
      ...prev,
      { role: 'user', content: text },
      { role: 'assistant', content: '', streaming: true },  // placeholder
    ])
    setLoading(true)
    setRoundStatus('Analyzing…')

    let streamedContent = ''

    const appendToLast = content => {
      setMessages(prev => {
        const next = [...prev]
        next[next.length - 1] = { role: 'assistant', content, streaming: true }
        return next
      })
    }

    try {
      await invokeAgentStreaming(config.streamUrl, token, text, {
        onRoundStart(round, total) {
          setRoundStatus(`Round ${round}/${total}: Generating mapping…`)
        },
        onToken(chunk) {
          streamedContent += chunk
          appendToLast(streamedContent)
        },
        onRoundEnd(round, score, passed) {
          if (!passed) {
            // Start fresh for the next round — only show the final iteration
            streamedContent = ''
            appendToLast('')
            setRoundStatus(`Round ${round} scored ${score}/5. Improving…`)
          }
        },
        onDone(score, rounds) {
          setMessages(prev => {
            const next = [...prev]
            next[next.length - 1] = {
              role: 'assistant',
              content: streamedContent,
              meta: `Score: ${score}/5 · Rounds: ${rounds}`,
              streaming: false,
            }
            return next
          })
          setRoundStatus(null)
        },
      }, config)
    } catch (err) {
      if (err instanceof QuotaError) {
        setQuotaExhausted(true)
        setMessages(prev => {
          const next = [...prev]
          next[next.length - 1] = { role: 'system', content: err.message }
          return next
        })
      } else {
        setMessages(prev => {
          const next = [...prev]
          next[next.length - 1] = { role: 'system', content: `Error: ${err.message}` }
          return next
        })
      }
      setRoundStatus(null)
    } finally {
      setLoading(false)
      setRoundStatus(null)
    }
  }

  const s = styles
  return (
    <div style={s.page}>
      <header style={s.header}>
        <span style={s.headerTitle}>🛡️ NIST 800-53 Assistant</span>
        <button style={s.logoutBtn} onClick={() => { logout(); onLogout() }}>Sign out</button>
      </header>

      <div style={s.messages}>
        {messages.map((msg, i) => (
          <div key={i} style={s.row(msg.role)}>
            {msg.role !== 'user' && <div style={s.avatar}>{msg.role === 'system' ? '⚠️' : '🛡️'}</div>}
            <div style={s.bubbleWrap}>
              <div style={s.bubble(msg.role)}>
                {msg.content || (msg.streaming ? <span style={s.cursor} /> : null)}
              </div>
              {msg.meta && <div style={s.meta}>{msg.meta}</div>}
            </div>
            {msg.role === 'user' && <div style={s.avatar}>👤</div>}
          </div>
        ))}

        {roundStatus && (
          <div style={s.statusRow}>
            <span style={s.spinner} />
            <span style={s.statusText}>{roundStatus}</span>
          </div>
        )}

        <div ref={bottomRef} />
      </div>

      <form style={s.inputBar} onSubmit={handleSubmit}>
        <input
          style={s.input}
          value={input}
          onChange={e => setInput(e.target.value)}
          placeholder={quotaExhausted ? 'Call limit reached' : 'Describe a cybersecurity issue…'}
          disabled={loading || quotaExhausted}
          autoFocus
        />
        <button
          style={s.sendBtn(!input.trim() || loading || quotaExhausted)}
          type="submit"
          disabled={!input.trim() || loading || quotaExhausted}
        >
          Send
        </button>
      </form>
    </div>
  )
}

const styles = {
  page: { height: '100vh', display: 'flex', flexDirection: 'column', background: '#f8fafc' },
  header: {
    display: 'flex', alignItems: 'center', justifyContent: 'space-between',
    padding: '14px 20px', background: '#0f172a', color: '#fff', flexShrink: 0,
  },
  headerTitle: { fontWeight: 600, fontSize: 16 },
  logoutBtn: {
    background: 'transparent', border: '1px solid rgba(255,255,255,0.3)',
    borderRadius: 6, color: '#cbd5e1', padding: '6px 14px', fontSize: 13, cursor: 'pointer',
  },
  messages: {
    flex: 1, overflowY: 'auto', padding: '24px 16px',
    display: 'flex', flexDirection: 'column', gap: 16,
    maxWidth: 800, width: '100%', margin: '0 auto',
  },
  row: role => ({
    display: 'flex', alignItems: 'flex-start', gap: 10,
    justifyContent: role === 'user' ? 'flex-end' : 'flex-start',
  }),
  avatar: { fontSize: 22, flexShrink: 0, marginTop: 2 },
  bubbleWrap: { display: 'flex', flexDirection: 'column', maxWidth: '75%', gap: 4 },
  bubble: role => ({
    padding: '12px 16px',
    borderRadius: role === 'user' ? '18px 18px 4px 18px' : '18px 18px 18px 4px',
    background: role === 'user' ? '#1d4ed8' : role === 'system' ? '#fef3c7' : '#fff',
    color: role === 'user' ? '#fff' : role === 'system' ? '#92400e' : '#1e293b',
    fontSize: 14, lineHeight: 1.6,
    boxShadow: '0 1px 3px rgba(0,0,0,0.1)',
    whiteSpace: 'pre-wrap', wordBreak: 'break-word', minHeight: 20,
  }),
  meta: { fontSize: 12, color: '#94a3b8', paddingLeft: 4 },
  cursor: {
    display: 'inline-block', width: 8, height: 14, background: '#94a3b8',
    borderRadius: 2, verticalAlign: 'text-bottom',
    animation: 'blink 1s step-end infinite',
  },
  statusRow: {
    display: 'flex', alignItems: 'center', gap: 8,
    padding: '0 4px', color: '#64748b', fontSize: 13,
  },
  spinner: {
    display: 'inline-block', width: 14, height: 14, flexShrink: 0,
    border: '2px solid #e2e8f0', borderTopColor: '#1d4ed8',
    borderRadius: '50%', animation: 'spin 0.8s linear infinite',
  },
  statusText: { fontStyle: 'italic' },
  inputBar: {
    display: 'flex', gap: 10, padding: '16px 20px',
    background: '#fff', borderTop: '1px solid #e2e8f0', flexShrink: 0,
    maxWidth: 800, width: '100%', alignSelf: 'center', margin: '0 auto', boxSizing: 'border-box',
  },
  input: {
    flex: 1, padding: '10px 16px', border: '1px solid #e2e8f0',
    borderRadius: 24, fontSize: 14, outline: 'none', background: '#f8fafc',
  },
  sendBtn: disabled => ({
    padding: '10px 20px', flexShrink: 0,
    background: disabled ? '#e2e8f0' : '#1d4ed8',
    color: disabled ? '#94a3b8' : '#fff',
    border: 'none', borderRadius: 24, fontSize: 14, fontWeight: 600,
    cursor: disabled ? 'not-allowed' : 'pointer', transition: 'background 0.15s',
  }),
}
