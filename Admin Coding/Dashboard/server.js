const express = require('express');
const { Pool } = require('pg');
const path = require('path');
const dotenv = require('dotenv');

// Load environment variables from jot-server/.env
dotenv.config({ path: path.join(__dirname, '../../jot-server/.env') });

const app = express();
const port = 3001;

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// API: Get all users
app.get('/api/users', async (req, res) => {
  try {
    const result = await pool.query(`
      SELECT 
        id, email, is_admin, 
        CASE WHEN (subscription_expiry > NOW() OR is_admin = true) THEN true ELSE false END as has_access,
        COALESCE(subscription_expiry::text, 'None') as expiry,
        created_at 
      FROM users 
      ORDER BY created_at DESC
    `);
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// API: Toggle Admin
app.post('/api/users/toggle-admin', async (req, res) => {
  const { email, isAdmin } = req.body;
  try {
    await pool.query('UPDATE users SET is_admin = $1 WHERE email = $2', [isAdmin, email]);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// API: Delete User (Trash)
app.post('/api/users/delete', async (req, res) => {
  const { id, email } = req.body;
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    
    // Delete all related data
    await client.query('DELETE FROM habit_logs WHERE habit_id IN (SELECT id FROM habits WHERE user_id = $1)', [id]);
    await client.query('DELETE FROM habits WHERE user_id = $1', [id]);
    await client.query('DELETE FROM ai_insights WHERE user_id = $1', [id]);
    await client.query('DELETE FROM log_entries WHERE user_id = $1', [id]);
    await client.query('DELETE FROM user_profiles WHERE user_id = $1', [id]);
    
    // Delete the user itself
    await client.query('DELETE FROM users WHERE id = $1', [id]);
    
    await client.query('COMMIT');
    res.json({ success: true });
  } catch (err) {
    await client.query('ROLLBACK');
    res.status(500).json({ error: err.message });
  } finally {
    client.release();
  }
});

// API: Recent Logs
app.get('/api/logs', async (req, res) => {
  try {
    const result = await pool.query(`
      SELECT l.*, u.email 
      FROM log_entries l 
      JOIN users u ON l.user_id = u.id 
      ORDER BY l.timestamp DESC 
      LIMIT 50
    `);
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Serve Dashboard (Express 5 syntax)
// Serve Dashboard (Universal Catch-all)
app.use((req, res) => {
  res.sendFile(path.join(__dirname, 'public/index.html'));
});

app.listen(port, '127.0.0.1', () => {
  console.log(`\x1b[35m🚀 Jot Admin Dashboard running at http://localhost:${port}\x1b[0m`);
  
  // Auto-open browser
  const { exec } = require('child_process');
  const url = `http://localhost:${port}`;
  const start = process.platform == 'darwin' ? 'open' : process.platform == 'win32' ? 'start' : 'xdg-open';
  exec(`${start} ${url}`);
});
