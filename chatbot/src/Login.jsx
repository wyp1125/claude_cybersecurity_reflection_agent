import { startLogin } from './auth.js'

export default function Login({ config }) {
  const s = styles

  return (
    <div style={s.page}>
      <div style={s.card}>
        <div style={s.shield}>🛡️</div>
        <h1 style={s.title}>NIST 800-53 Assistant</h1>
        <p style={s.subtitle}>
          Map cybersecurity issues to NIST 800-53 controls using AI-powered analysis.
        </p>
        <button style={s.googleBtn} onClick={() => startLogin(config)}>
          <GoogleIcon />
          Sign in with Google
        </button>
      </div>
    </div>
  )
}

function GoogleIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 18 18" style={{ marginRight: 10, flexShrink: 0 }}>
      <path fill="#4285F4" d="M17.64 9.2c0-.637-.057-1.251-.164-1.84H9v3.481h4.844c-.209 1.125-.843 2.078-1.796 2.717v2.258h2.908c1.702-1.567 2.684-3.875 2.684-6.615z"/>
      <path fill="#34A853" d="M9 18c2.43 0 4.467-.806 5.956-2.18l-2.908-2.259c-.806.54-1.837.86-3.048.86-2.344 0-4.328-1.584-5.036-3.711H.957v2.332A8.997 8.997 0 009 18z"/>
      <path fill="#FBBC05" d="M3.964 10.71A5.41 5.41 0 013.682 9c0-.593.102-1.17.282-1.71V4.958H.957A8.996 8.996 0 000 9c0 1.452.348 2.827.957 4.042l3.007-2.332z"/>
      <path fill="#EA4335" d="M9 3.58c1.321 0 2.508.454 3.44 1.345l2.582-2.58C13.463.891 11.426 0 9 0A8.997 8.997 0 00.957 4.958L3.964 7.29C4.672 5.163 6.656 3.58 9 3.58z"/>
    </svg>
  )
}

const styles = {
  page: {
    minHeight: '100vh',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    background: 'linear-gradient(135deg, #0f172a 0%, #1e3a5f 100%)',
  },
  card: {
    background: '#fff',
    borderRadius: 16,
    padding: '48px 40px',
    width: '100%',
    maxWidth: 400,
    textAlign: 'center',
    boxShadow: '0 25px 60px rgba(0,0,0,0.35)',
  },
  shield: {
    fontSize: 48,
    marginBottom: 16,
    display: 'block',
  },
  title: {
    fontSize: 24,
    fontWeight: 700,
    color: '#0f172a',
    marginBottom: 12,
  },
  subtitle: {
    fontSize: 14,
    color: '#64748b',
    lineHeight: 1.6,
    marginBottom: 32,
  },
  googleBtn: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    width: '100%',
    padding: '12px 20px',
    border: '1px solid #e2e8f0',
    borderRadius: 8,
    background: '#fff',
    color: '#0f172a',
    fontSize: 15,
    fontWeight: 500,
    cursor: 'pointer',
    transition: 'background 0.15s',
  },
}
