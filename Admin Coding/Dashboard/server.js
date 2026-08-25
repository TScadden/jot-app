const express = require('express');
const { Pool } = require('pg');
const path = require('path');
const dotenv = require('dotenv');

// Load environment variables from jot-server/.env
dotenv.config({ path: path.join(__dirname, '../../jot-server/.env') });

const crypto = require('crypto');

const app = express();
const port = 3001;

// Cryptographically random launch token
const ADMIN_TOKEN = crypto.randomBytes(32).toString('hex');

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

app.use(express.json());

// Authentication and CSRF defense middleware
const authMiddleware = (req, res, next) => {
  // 1. Origin and Referer checks to protect against CSRF
  const origin = req.headers.origin;
  const referer = req.headers.referer;
  const allowedHost = 'localhost:3001';
  const allowedHostIp = '127.0.0.1:3001';

  if (origin) {
    try {
      const originUrl = new URL(origin);
      if (originUrl.host !== allowedHost && originUrl.host !== allowedHostIp) {
        return res.status(403).json({ error: 'Forbidden: Invalid request origin' });
      }
    } catch (e) {
      return res.status(403).json({ error: 'Forbidden: Malformed request origin' });
    }
  } else if (referer) {
    try {
      const refererUrl = new URL(referer);
      if (refererUrl.host !== allowedHost && refererUrl.host !== allowedHostIp) {
        return res.status(403).json({ error: 'Forbidden: Invalid request referer' });
      }
    } catch (e) {
      return res.status(403).json({ error: 'Forbidden: Malformed request referer' });
    }
  }

  // 2. Token validation
  const token = req.headers['x-admin-token'];
  if (!token || token !== ADMIN_TOKEN) {
    return res.status(401).json({ error: 'Unauthorized: Invalid or missing token' });
  }

  next();
};

// Apply auth/CSRF middleware to all API endpoints
app.use('/api', authMiddleware);

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
    res.status(500).json({ error: 'Internal Server Error' });
  }
});

// API: Toggle Admin
app.post('/api/users/toggle-admin', async (req, res) => {
  const { email, isAdmin } = req.body;
  
  // Validate input parameters
  if (typeof email !== 'string' || !email.includes('@') || typeof isAdmin !== 'boolean') {
    return res.status(400).json({ error: 'Bad Request: Invalid body parameters' });
  }

  try {
    await pool.query('UPDATE users SET is_admin = $1 WHERE email = $2', [isAdmin, email]);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: 'Internal Server Error' });
  }
});

// API: Delete User (Trash)
app.post('/api/users/delete', async (req, res) => {
  const { id, email } = req.body;

  // Validate input parameters
  if (typeof id !== 'string' || id.trim() === '' || typeof email !== 'string' || !email.includes('@')) {
    return res.status(400).json({ error: 'Bad Request: Invalid body parameters' });
  }

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
    res.status(500).json({ error: 'Internal Server Error' });
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
    res.status(500).json({ error: 'Internal Server Error' });
  }
});

// Serve Dashboard (Universal Catch-all)
app.use((req, res) => {
  res.sendFile(path.join(__dirname, 'public/index.html'));
});

app.listen(port, '127.0.0.1', () => {
  console.log(`\x1b[35m🚀 Jot Admin Dashboard running at http://localhost:${port}\x1b[0m`);
  
  // Auto-open browser with the launch token
  const { exec } = require('child_process');
  const url = `http://localhost:${port}/?token=${ADMIN_TOKEN}`;
  const start = process.platform == 'darwin' ? 'open' : process.platform == 'win32' ? 'start' : 'xdg-open';
  exec(`${start} ${url}`);
});
