// --- Skill loading ---
function loadSkillList() {
    if (!apiKey) return;
     authFetch('/api/v1/skills').then(function(r) { return r.json(); }).then(function(data) {
        skillList = data.skills || data || [];
        renderSkillList();
    }).catch(function() {});
}
function renderSkillList() {
    var el = document.getElementById('skill-list');
    el.innerHTML = '';
    var skills = skillList;
    if (!Array.isArray(skills)) return;
    skills.forEach(function(sk) {
        var name = sk.name || sk;
        var desc = sk.description || sk.always || '';
        var div = document.createElement('div');
        div.className = 'skill-item';
        div.innerHTML = '<div class="skill-name">' + escHtml(name) + '</div>' + (desc ? '<div class="skill-desc">' + escHtml(desc) + '</div>' : '');
        div.onclick = function() { startChatWithSkill(name); };
        el.appendChild(div);
    });
}
function startChatWithSkill(skillName) {
    if (!ws || ws.readyState !== WebSocket.OPEN) { navigate('/chat'); return; }
    navigate('/chat');
    if (!currentTopicId) {
        ws.send(JSON.stringify({type: 'new_topic', title: 'Skill: ' + skillName, channel_id: 'general'}));
    }
    setTimeout(function() {
        if (currentTopicId) {
            ws.send(JSON.stringify({type: 'chat', content: 'Load and use the skill: ' + skillName}));
        }
    }, 500);
}

