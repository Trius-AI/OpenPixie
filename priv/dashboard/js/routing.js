// --- Icon Bar ---
function renderIconBar(containerId) {
    var el = document.getElementById(containerId);
    if (el && !el.hasChildNodes()) {
        el.innerHTML = '<button class="icon-btn" onclick="navigate(\'/dashboard\')" title="Home">&#8962;</button>'
            + '<div class="icon-sep"></div>'
            + '<button class="icon-btn" onclick="navigate(\'/files\')" title="Files">&#128193;</button>'
            + '<button class="icon-btn" onclick="navigate(\'/settings\')" title="Settings">&#9881;</button>'
            + '<button class="icon-btn" onclick="logout()" title="Logout">&#9211;</button>';
    }
}

// --- Routing ---
var sessionChecked = false;
function navigate(path) {
    history.pushState(null, '', path);
    route();
}
function route() {
    var path = location.pathname;
    if (!apiKey && path !== '/login') {
        if (!sessionChecked) { checkSession().then(function(ok) { sessionChecked = true; if (ok) { apiKey = 'session'; route(); } else { navigate('/login'); } }); return; }
        navigate('/login'); return;
    }
    document.querySelectorAll('.page').forEach(function(p) { p.classList.remove('active'); });
    if (path === '/dashboard') {
        document.getElementById('page-dashboard').classList.add('active');
        loadSkillList();
    } else if (path === '/chat' || path.indexOf('/chat/') === 0) {
        var urlTopicId = path.indexOf('/chat/') === 0 ? path.substring(6) : null;
        if (urlTopicId && ws && ws.readyState === WebSocket.OPEN && urlTopicId !== currentTopicId) {
            ws.send(JSON.stringify({type: 'switch_topic', topic_id: urlTopicId}));
        }
        document.getElementById('page-chat').classList.add('active');
    } else if (path === '/settings') {
        document.getElementById('page-settings').classList.add('active');
        renderIconBar('sidebar-icon-bar');
        if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({type: 'get_config'}));
        }
        loadSoulEditor();
        loadApiKeyDisplay();
        loadRawConfig();
        loadSkillsList();
        loadToolsList();
        loadGitSettings();
    } else if (path === '/guardian') {
        document.getElementById('page-guardian').classList.add('active');
        renderIconBar('guardian-icon-bar');
    } else if (path === '/files') {
        document.getElementById('page-files').classList.add('active');
        renderIconBar('files-icon-bar');
        filesBrowse('/');
    } else if (path === '/skill2tool') {
        document.getElementById('page-skill2tool').classList.add('active');
        renderIconBar('skill2tool-icon-bar');
    } else if (path === '/login') {
        document.getElementById('page-login').classList.add('active');
    } else {
        if (apiKey) { navigate('/dashboard'); } else { navigate('/login'); }
        return;
    }
}
window.addEventListener('popstate', route);

