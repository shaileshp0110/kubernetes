import { useState, useEffect } from 'react'

function App() {
  const [users, setUsers] = useState([])
  const [name, setName] = useState('')
  const [email, setEmail] = useState('')

  const fetchUsers = async () => {
    try {
      // Ingress will route /api to the backend
      const response = await fetch('/api/users')
      if (response.ok) {
        const data = await response.json()
        setUsers(data)
      }
    } catch (error) {
      console.error('Error fetching users:', error)
    }
  }

  useEffect(() => {
    fetchUsers()
  }, [])

  const addUser = async (e) => {
    e.preventDefault()
    try {
      const response = await fetch('/api/users', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, email })
      })
      if (response.ok) {
        setName('')
        setEmail('')
        fetchUsers()
      }
    } catch (error) {
      console.error('Error adding user:', error)
    }
  }

  const deleteUser = async (id) => {
    try {
      const response = await fetch(`/api/users/${id}`, {
        method: 'DELETE'
      })
      if (response.ok) {
        fetchUsers()
      }
    } catch (error) {
      console.error('Error deleting user:', error)
    }
  }

  return (
    <div style={{ padding: '2rem', fontFamily: 'sans-serif' }}>
      <h1>User Management (Frontend)</h1>
      <form onSubmit={addUser} style={{ marginBottom: '1rem' }}>
        <input 
          value={name} 
          onChange={e => setName(e.target.value)} 
          placeholder="Name" 
          required 
          style={{ marginRight: '0.5rem', padding: '0.5rem' }} 
        />
        <input 
          value={email} 
          onChange={e => setEmail(e.target.value)} 
          placeholder="Email" 
          type="email" 
          required 
          style={{ marginRight: '0.5rem', padding: '0.5rem' }} 
        />
        <button type="submit" style={{ padding: '0.5rem 1rem' }}>Add User</button>
      </form>

      {users.length === 0 ? <p>No users found. Add one above.</p> : null}
      <ul style={{ listStyleType: 'none', padding: 0 }}>
        {users.map(user => (
          <li key={user.id} style={{ margin: '0.5rem 0', padding: '0.5rem', border: '1px solid #ccc', borderRadius: '4px', display: 'flex', justifyContent: 'space-between', maxWidth: '400px' }}>
            <span>{user.name} ({user.email})</span>
            <button onClick={() => deleteUser(user.id)} style={{ color: 'red', border: 'none', background: 'none', cursor: 'pointer' }}>Delete</button>
          </li>
        ))}
      </ul>
    </div>
  )
}

export default App
