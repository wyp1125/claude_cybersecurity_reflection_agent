import { useState, useEffect } from 'react'
import Login from './Login.jsx'
import Chat from './Chat.jsx'
import { handleCallback, getToken } from './auth.js'

export default function App() {
  const [config, setConfig] = useState(null)
  const [token, setToken] = useState(null)
  const [error, setError] = useState(null)

  // Load runtime config, then handle OAuth callback or restore session
  useEffect(() => {
    fetch('/config.json')
      .then(r => r.json())
      .then(async cfg => {
        setConfig(cfg)

        // If returning from Cognito with ?code=..., exchange for token
        if (window.location.search.includes('code=')) {
          const ok = await handleCallback(cfg)
          if (!ok) { setError('Login failed. Please try again.'); return }
        }

        const stored = getToken()
        if (stored) setToken(stored)
      })
      .catch(() => setError('Failed to load configuration.'))
  }, [])

  if (error) return <ErrorScreen message={error} />
  if (!config) return <LoadingScreen />
  if (!token) return <Login config={config} />
  return <Chat config={config} token={token} onLogout={() => setToken(null)} />
}

function LoadingScreen() {
  return (
    <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', background: '#0f172a' }}>
      <span style={{ color: '#94a3b8', fontSize: 16 }}>Loading…</span>
    </div>
  )
}

function ErrorScreen({ message }) {
  return (
    <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', background: '#0f172a' }}>
      <div style={{ background: '#fff', borderRadius: 12, padding: 32, maxWidth: 360, textAlign: 'center' }}>
        <div style={{ fontSize: 36, marginBottom: 16 }}>⚠️</div>
        <p style={{ color: '#64748b', fontSize: 14 }}>{message}</p>
      </div>
    </div>
  )
}
