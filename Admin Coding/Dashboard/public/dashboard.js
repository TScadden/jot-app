// Retrieve and clean token from URL query params
const urlParams = new URLSearchParams(window.location.search);
const urlToken = urlParams.get('token');
if (urlToken) {
    sessionStorage.setItem('adminToken', urlToken);
    // Clean up address bar
    const cleanUrl = window.location.origin + window.location.pathname;
    window.history.replaceState({}, document.title, cleanUrl);
}
const adminToken = sessionStorage.getItem('adminToken') || '';

async function loadData() {
    const btn = document.getElementById('refresh-btn');
    const icon = document.getElementById('refresh-icon');
    
    btn.classList.add('loading');
    icon.classList.add('spinning');

    try {
        // Fetch data and wait at least 1 second for the "satisfying" spin
        const [usersRes, logsRes] = await Promise.all([
            fetch('/api/users', { headers: { 'X-Admin-Token': adminToken } }),
            fetch('/api/logs', { headers: { 'X-Admin-Token': adminToken } }),
            new Promise(resolve => setTimeout(resolve, 1000))
        ]);
        
        if (usersRes.status === 401 || usersRes.status === 403 || logsRes.status === 401 || logsRes.status === 403) {
            showToast('Unauthorized. Please relaunch the admin dashboard from the server.', true);
            return;
        }

        const users = await usersRes.json();
        const logs = await logsRes.json();

        renderUsers(users);
        renderLogs(logs);
        updateStats(users);
    } catch (err) {
        console.error(err);
        showToast('Failed to load data', true);
    } finally {
        btn.classList.remove('loading');
        icon.classList.remove('spinning');
    }
}

function updateStats(users) {
    document.getElementById('total-users').textContent = users.length;
    document.getElementById('unlimited-users').textContent = users.filter(u => u.has_access).length;
    document.getElementById('admin-count').textContent = users.filter(u => u.is_admin).length;
}

function renderUsers(users) {
    const tbody = document.getElementById('users-table');
    tbody.textContent = ''; // Clear existing contents safely
    
    users.forEach(user => {
        const tr = document.createElement('tr');
        
        const tdEmail = document.createElement('td');
        tdEmail.style.fontWeight = '600';
        tdEmail.textContent = user.email;
        tr.appendChild(tdEmail);
        
        const tdStatus = document.createElement('td');
        const spanStatus = document.createElement('span');
        spanStatus.className = `badge ${user.is_admin ? 'badge-admin' : 'badge-none'}`;
        spanStatus.textContent = user.is_admin ? 'ADMIN' : 'USER';
        tdStatus.appendChild(spanStatus);
        tr.appendChild(tdStatus);
        
        const tdAccess = document.createElement('td');
        const spanAccess = document.createElement('span');
        spanAccess.className = `badge ${user.has_access ? 'badge-access' : 'badge-none'}`;
        spanAccess.textContent = user.has_access ? 'UNLIMITED' : 'STANDARD';
        tdAccess.appendChild(spanAccess);
        tr.appendChild(tdAccess);
        
        const tdExpiry = document.createElement('td');
        tdExpiry.className = 'timestamp';
        tdExpiry.textContent = user.expiry.split(' ')[0];
        tr.appendChild(tdExpiry);
        
        const tdJoined = document.createElement('td');
        tdJoined.className = 'timestamp';
        tdJoined.textContent = new Date(user.created_at).toLocaleDateString();
        tr.appendChild(tdJoined);
        
        const tdActions = document.createElement('td');
        tdActions.style.textAlign = 'right';
        tdActions.style.display = 'flex';
        tdActions.style.gap = '8px';
        tdActions.style.justifyContent = 'flex-end';
        
        const btnToggle = document.createElement('button');
        btnToggle.className = `btn btn-sm ${user.is_admin ? 'btn-outline' : ''}`;
        btnToggle.textContent = user.is_admin ? 'Revoke Admin' : 'Make Admin';
        btnToggle.addEventListener('click', () => toggleAdmin(user.email, !user.is_admin));
        tdActions.appendChild(btnToggle);
        
        const btnDelete = document.createElement('button');
        btnDelete.className = 'btn btn-sm btn-danger';
        btnDelete.textContent = 'Remove Account';
        btnDelete.addEventListener('click', () => trashAccount(user.id, user.email));
        tdActions.appendChild(btnDelete);
        
        tr.appendChild(tdActions);
        tbody.appendChild(tr);
    });
}

function renderLogs(logs) {
    const tbody = document.getElementById('logs-table');
    tbody.textContent = ''; // Clear existing contents safely
    
    logs.forEach(log => {
        const tr = document.createElement('tr');
        
        const tdUser = document.createElement('td');
        tdUser.style.fontSize = '0.85rem';
        tdUser.style.color = 'var(--text-dim)';
        tdUser.textContent = log.email;
        tr.appendChild(tdUser);
        
        const tdCategory = document.createElement('td');
        const spanCategory = document.createElement('span');
        spanCategory.className = 'badge badge-none';
        spanCategory.textContent = log.category_id;
        tdCategory.appendChild(spanCategory);
        tr.appendChild(tdCategory);
        
        const tdBody = document.createElement('td');
        tdBody.style.maxWidth = '400px';
        tdBody.style.whiteSpace = 'nowrap';
        tdBody.style.overflow = 'hidden';
        tdBody.style.textOverflow = 'ellipsis';
        tdBody.textContent = log.body;
        tr.appendChild(tdBody);
        
        const tdTime = document.createElement('td');
        tdTime.className = 'timestamp';
        tdTime.textContent = new Date(log.timestamp).toLocaleString();
        tr.appendChild(tdTime);
        
        tbody.appendChild(tr);
    });
}

async function trashAccount(id, email) {
    if (!confirm(`⚠️ CRITICAL ACTION: Are you sure you want to PERMANENTLY TRASH the account for ${email}? \n\nThis will delete ALL logs, habits, documents, and login access forever.`)) return;
    
    try {
        const res = await fetch('/api/users/delete', {
            method: 'POST',
            headers: { 
                'Content-Type': 'application/json',
                'X-Admin-Token': adminToken
            },
            body: JSON.stringify({ id, email })
        });
        if (res.ok) {
            showToast(`Successfully removed ${email}`);
            loadData();
        } else {
            showToast('Trash failed', true);
        }
    } catch (err) {
        showToast('Trash failed', true);
    }
}

async function toggleAdmin(email, isAdmin) {
    try {
        const res = await fetch('/api/users/toggle-admin', {
            method: 'POST',
            headers: { 
                'Content-Type': 'application/json',
                'X-Admin-Token': adminToken
            },
            body: JSON.stringify({ email, isAdmin })
        });
        if (res.ok) {
            showToast(`${email} is now ${isAdmin ? 'an Admin' : 'a User'}`);
            loadData();
        } else {
            showToast('Action failed', true);
        }
    } catch (err) {
        showToast('Action failed', true);
    }
}

function showToast(msg, isError = false) {
    const toast = document.getElementById('toast');
    toast.textContent = msg;
    toast.style.background = isError ? 'var(--error)' : 'var(--primary)';
    toast.classList.add('show');
    setTimeout(() => toast.classList.remove('show'), 3000);
}

// Add event listener to refresh button
document.getElementById('refresh-btn').addEventListener('click', loadData);

// Initial Load
loadData();
// Auto-refresh every 60 seconds
setInterval(loadData, 60000);
