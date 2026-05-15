        function sendFrontendError(message, source, lineno, colno, stack) {
            if (ws && ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({
                    type: 'frontend_error',
                    message: String(message || ''),
                    source: String(source || ''),
                    lineno: lineno || 0,
                    colno: colno || 0,
                    stack: String(stack || '')
                }));
            }
        }
        window.onerror = function(message, source, lineno, colno, error) {
            sendFrontendError(message, source, lineno, colno, error && error.stack || '');
        };
        window.addEventListener('unhandledrejection', function(event) {
            var reason = event.reason;
            sendFrontendError(reason && reason.message || String(reason), '', 0, 0, reason && reason.stack || '');
        });

        // --- State ---
        let ws = null;
        let apiKey = '';
        let currentTopicId = null;
        let currentTopicStatus = null;
        let heartbeatTimer = null;
        let lastThinkingEl = null;
        let streamingEl = null;
        let streamingRawText = '';
        let isSending = false;
        let currentToolConfirmData = null;
        let agentTopicId = null;
        let skillList = [];
        const tabId = sessionStorage.getItem('openpixie_tab_id') || (sessionStorage.setItem('openpixie_tab_id', crypto.randomUUID()), sessionStorage.getItem('openpixie_tab_id'));
        const topicStates = {};

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
            } else if (path === '/chat') {
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

        // --- Topic state ---
        function getTopicState(topicId) {
            if (!topicStates[topicId]) topicStates[topicId] = {};
            return topicStates[topicId];
        }
        function markUnread(topicId) {
            if (!topicId || topicId === currentTopicId) return;
            var s = getTopicState(topicId);
            s.unread = (s.unread || 0) + 1;
            var dot = document.querySelector('.topic-item[data-topic-id="' + topicId + '"] .status-dot');
            if (dot) dot.classList.add('unread');
        }
        function clearUnread(topicId) {
            if (!topicId) return;
            var s = getTopicState(topicId);
            s.unread = 0;
            var dot = document.querySelector('.topic-item[data-topic-id="' + topicId + '"] .status-dot');
            if (dot) dot.classList.remove('unread');
        }
        function saveCurrentTopicState() {
            if (!currentTopicId) return;
            var s = getTopicState(currentTopicId);
            s.isSending = (agentTopicId === currentTopicId) && isSending;
            s.hasToolConfirm = (agentTopicId === currentTopicId) && !!document.getElementById('tool-confirm-bar');
            s.toolConfirmData = s.hasToolConfirm ? currentToolConfirmData : null;
        }
        function restoreTopicState(topicId) {
            var s = getTopicState(topicId);
            isSending = (agentTopicId === topicId) || !!s.isSending;
            streamingEl = null;
            lastThinkingEl = null;
            lastToolStepEl = null;
            updateSendButton();
            if (s.hasToolConfirm && s.toolConfirmData) {
                showToolConfirm(s.toolConfirmData.tool, s.toolConfirmData.args, s.toolConfirmData.reason);
            } else {
                hideToolConfirm();
            }
        }

        function loadKey() {
            apiKey = sessionStorage.getItem('openpixie_api_key') || '';
            return !!apiKey;
        }
        function checkSession() {
            return fetch('/api/v1/config', {credentials: 'same-origin'}).then(function(r) {
                if (r.status === 401) { forceLogout(); return false; }
                return r.ok;
            }).catch(function() { return false; });
        }
        function forceLogout() {
            sessionStorage.removeItem('openpixie_api_key');
            apiKey = '';
            if (ws) ws.close();
            showLogin('Session expired. Please log in again.');
        }
        function authFetch(url, opts) {
            var optsWithCreds = Object.assign({credentials: 'same-origin'}, opts || {});
            return fetch(url, optsWithCreds).then(function(r) {
                if (r.status === 401) { forceLogout(); throw new Error('Session expired'); }
                return r;
            });
        }
        function login() {
            var key = document.getElementById('api-key-input').value.trim();
            if (!key) return;
            document.getElementById('login-error').style.display = 'none';
            fetch('/api/v1/login', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({api_key: key})
            }).then(function(r) { return r.json(); }).then(function(data) {
                if (data.success) {
                    apiKey = key;
                    sessionStorage.setItem('openpixie_api_key', key);
                    connect();
                } else {
                    showLogin(data.error || 'Authentication failed');
                }
            }).catch(function() {
                showLogin('Connection failed');
            });
        }
        function showLogin(err) {
            navigate('/login');
            if (err) {
                var el = document.getElementById('login-error');
                el.textContent = err;
                el.style.display = 'block';
            }
        }
        function logout() {
            fetch('/api/v1/login', {method: 'DELETE', credentials: 'same-origin'}).catch(function() {});
            sessionStorage.removeItem('openpixie_api_key');
            apiKey = '';
            if (ws) ws.close();
            navigate('/login');
        }

        function connect() {
            if (ws && (ws.readyState === WebSocket.CONNECTING || ws.readyState === WebSocket.OPEN)) return;
            var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
            var url = proto + '//' + location.host + '/ws';
            document.getElementById('status').textContent = 'Connecting...';
            ws = new WebSocket(url);
            ws.onopen = function() {
                document.getElementById('status').textContent = 'Connected';
                hideBanner();
                document.getElementById('chat-area').style.display = 'block';
                document.getElementById('input-area').style.display = 'flex';
                var savedMode = localStorage.getItem('openpixie_perm_mode');
                if (savedMode) {
                    ws.send(JSON.stringify({type: 'set_permission_mode', mode: savedMode}));
                    document.getElementById('perm-mode').value = savedMode;
                }
                var lastTopic = localStorage.getItem('openpixie_last_topic');
                if (lastTopic) {
                    ws.send(JSON.stringify({type: 'connect', topic_id: lastTopic}));
                } else {
                    ws.send(JSON.stringify({type: 'connect'}));
                }
                ws.send(JSON.stringify({type: 'list_topics'}));
                resetHeartbeat();
                if (location.pathname === '/' || location.pathname === '/login') {
                    navigate('/dashboard');
                }
            };
            ws.onmessage = function(e) {
                try { handleServerMessage(JSON.parse(e.data)); } catch(err) { console.error('Failed to parse WS message:', err); }
            };
            ws.onclose = function(e) {
                clearTimeout(heartbeatTimer);
                if (e.code === 401 || e.code === 1008) {
                    sessionStorage.removeItem('openpixie_api_key');
                    apiKey = '';
                    showLogin('Session expired. Please log in again.');
                } else {
                    finalizeStreaming();
                    isSending = false; agentTopicId = null; hideToolConfirm(); updateSendButton();
                    showBanner('Connection lost — reconnecting...');
                    document.getElementById('status').textContent = 'Reconnecting...';
                    setTimeout(connect, 2000);
                }
            };
            ws.onerror = function() { document.getElementById('status').textContent = 'Connection error'; };
        }
        function resetHeartbeat() {
            clearTimeout(heartbeatTimer);
            heartbeatTimer = setTimeout(function() { console.log('Heartbeat timeout'); if (ws) ws.close(); }, 65000);
        }
        function finalizeStreaming() { streamingEl = null; streamingRawText = ''; }

        function handleServerMessage(data) {
            resetHeartbeat();
            switch (data.type) {
                case 'heartbeat': if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({type: 'heartbeat'})); break;
                case 'connected':
                    saveCurrentTopicState(); clearUnread(currentTopicId);
                    currentTopicId = data.topic_id; currentTopicStatus = data.status || 'active';
                    localStorage.setItem('openpixie_last_topic', data.topic_id);
                    document.getElementById('topic-title').textContent = data.title || 'New conversation';
                    var meta = '#' + (data.channel_id || 'general');
                    if (data.parent_id) meta += ' · forked from ' + data.parent_id.substring(0, 8);
                    document.getElementById('topic-meta').textContent = meta;
                    if (data.permission_mode) { document.getElementById('perm-mode').value = data.permission_mode; localStorage.setItem('openpixie_perm_mode', data.permission_mode); }
                    clearChat();
                    if (data.history && data.history.length > 0) { data.history.forEach(function(m) { try { addMessage(m.role, m.content, null, m); } catch(e) { console.error('Failed to render message:', e); } }); }
                    if (topicStates[data.topic_id]) { restoreTopicState(data.topic_id); } else { isSending = false; updateSendButton(); hideToolConfirm(); }
                    updateResolveBtn(); break;
                case 'message':
                    removeThinking();
                    if (data.topic_id === currentTopicId) { finalizeStreaming(); addMessage(data.data.role, data.data.content); } else { markUnread(data.topic_id); }
                    break;
                case 'response': {
                    var respTopic = agentTopicId;
                    if (respTopic) getTopicState(respTopic).isSending = false;
                    agentTopicId = null;
                    if (respTopic === currentTopicId) { removeThinking(); if (streamingEl) { var respContent = data.message && data.message.content; if (respContent && String(respContent).trim() !== '') { var cSpan = streamingEl.querySelector('.msg-content'); if (cSpan && (!streamingEl._rawText || streamingEl._rawText.trim() === '')) { cSpan.innerHTML = renderMarkdown(respContent); cSpan.className = 'msg-content md'; streamingEl._rawText = respContent; } } streamingEl = null; streamingRawText = ''; } else if (data.message && data.message.content && String(data.message.content).trim() !== '') { addMessage('assistant', data.message.content); } hideToolConfirm(); }
                    else if (respTopic) { markUnread(respTopic); getTopicState(respTopic).hasToolConfirm = false; getTopicState(respTopic).toolConfirmData = null; }
                    isSending = false; updateSendButton(); break;
                }
                case 'chunk':
                    if (agentTopicId && agentTopicId !== currentTopicId) { markUnread(agentTopicId); break; }
                    removeThinking();
                    if (data.content) {
                        if (!streamingEl || !streamingEl.parentNode) { streamingEl = addMessage('assistant', '\u200B', null, null, true); streamingEl._rawText = ''; }
                        var contentSpan = streamingEl.querySelector('.msg-content') || streamingEl;
                        streamingRawText = (streamingEl._rawText || '') + data.content;
                        streamingEl._rawText = streamingRawText;
                        contentSpan.innerHTML = renderMarkdown(streamingRawText);
                        contentSpan.className = 'msg-content md';
                        document.getElementById('chat-area').scrollTop = document.getElementById('chat-area').scrollHeight;
                    }
                    break;
                case 'thinking': if (agentTopicId && agentTopicId !== currentTopicId) break; if (!streamingEl) { removeThinking(); lastThinkingEl = addMessage('thinking', 'Thinking...', data.topic_id); } break;
                case 'stream_done':
                    if (agentTopicId && agentTopicId !== currentTopicId) { markUnread(agentTopicId); break; }
                    if (streamingEl) { var cSpan = streamingEl.querySelector('.msg-content'); if (cSpan) { var finalText = streamingEl._rawText || streamingRawText || cSpan.textContent; cSpan.innerHTML = renderMarkdown(finalText); cSpan.className = 'msg-content md'; } }
                    streamingEl = null; streamingRawText = ''; break;
                case 'interrupted': {
                    var intTopic = agentTopicId; agentTopicId = null;
                    if (intTopic === currentTopicId) { isSending = false; finalizeStreaming(); removeThinking(); updateSendButton(); hideToolConfirm(); }
                    else if (intTopic) { getTopicState(intTopic).isSending = false; getTopicState(intTopic).hasToolConfirm = false; getTopicState(intTopic).toolConfirmData = null; }
                    else { isSending = false; finalizeStreaming(); removeThinking(); updateSendButton(); hideToolConfirm(); }
                    break;
                }
                case 'permission_mode_set':
                    if (data.mode) { document.getElementById('perm-mode').value = data.mode; localStorage.setItem('openpixie_perm_mode', data.mode); }
                    break;
                case 'ask_user_request':
                    if (agentTopicId && agentTopicId !== currentTopicId) break;
                    showAskUserModal(data.tool, data.question, data.context || ''); break;
                case 'ask_user_received': break;
                case 'dashboard_refresh_hint': showRefreshBanner(); break;
                case 'topic_not_found': case 'topic_died': case 'topic_load_failed': case 'topic_subscribe_failed':
                    addMessage('system', 'This topic is no longer available. Please select or create a new one.');
                    if (currentTopicId) ws.send(JSON.stringify({type: 'list_topics'})); break;
                case 'error': {
                    var errTopic = agentTopicId; agentTopicId = null;
                    if (errTopic === currentTopicId || !errTopic) { removeThinking(); finalizeStreaming(); addMessage('system', data.message || data.error || 'Unknown error'); }
                    if (errTopic) getTopicState(errTopic).isSending = false;
                    isSending = false; updateSendButton(); break;
                }
                case 'tool_confirm_request':
                    if (agentTopicId) {
                        var confirmData = {tool: data.tool, args: data.args, reason: data.reason};
                        getTopicState(agentTopicId).hasToolConfirm = true; getTopicState(agentTopicId).toolConfirmData = confirmData;
                        if (agentTopicId === currentTopicId) { removeThinking(); streamingEl = null; showToolConfirm(data.tool, data.args, data.reason); }
                        else { markUnread(agentTopicId); }
                    }
                    break;
                case 'tool_step':
                    if (agentTopicId && agentTopicId !== currentTopicId) { markUnread(agentTopicId); break; }
                    removeThinking(); streamingEl = null; showToolStep(data.tool, data.args, data.status); break;
                case 'guardian_check':
                    if (agentTopicId && agentTopicId !== currentTopicId) { markUnread(agentTopicId); break; }
                    addGuardianMessage(data.tool, 'checking', null, data.args);
                    break;
                case 'guardian_result':
                    if (agentTopicId && agentTopicId !== currentTopicId) { markUnread(agentTopicId); break; }
                    addGuardianMessage(data.tool, data.status, data.reason, null);
                    break;
                case 'topic_created':
                    saveCurrentTopicState(); currentTopicId = data.topic_id; currentTopicStatus = 'active';
                    localStorage.setItem('openpixie_last_topic', data.topic_id);
                    document.getElementById('topic-title').textContent = data.title || 'Untitled';
                    document.getElementById('topic-meta').textContent = '#' + (data.channel_id || 'general');
                    clearChat(); isSending = false; updateSendButton(); hideToolConfirm(); updateResolveBtn();
                    ws.send(JSON.stringify({type: 'list_topics'})); break;
                case 'topic_switched':
                    saveCurrentTopicState(); clearUnread(currentTopicId); currentTopicId = data.topic_id; currentTopicStatus = data.status || 'active';
                    localStorage.setItem('openpixie_last_topic', data.topic_id);
                    document.getElementById('topic-title').textContent = data.title || 'Untitled';
                    document.getElementById('topic-meta').textContent = '#' + (data.channel_id || 'general');
                    clearChat();
                    if (data.history && data.history.length > 0) { data.history.forEach(function(m) { try { addMessage(m.role, m.content, null, m); } catch(e) { console.error('Failed to render message:', e); } }); }
                    if (topicStates[data.topic_id]) { restoreTopicState(data.topic_id); } else { isSending = false; updateSendButton(); hideToolConfirm(); }
                    updateResolveBtn(); ws.send(JSON.stringify({type: 'list_topics'})); break;
                case 'topics_list': renderSidebar(data.topics, data.channels); break;
                case 'retry_started':
                    var retryIdx = data.message_index;
                    if (retryIdx !== undefined) {
                        var msgs = document.getElementById('chat-area').querySelectorAll('.msg');
                        var userCount = -1;
                        for (var ri = 0; ri < msgs.length; ri++) {
                            if (msgs[ri].classList.contains('user')) {
                                userCount++;
                                if (userCount >= retryIdx) {
                                    while (ri + 1 < msgs.length) { msgs[ri + 1].remove(); msgs = document.getElementById('chat-area').querySelectorAll('.msg'); }
                                    break;
                                }
                            }
                        }
                        messageIndex = retryIdx + 1;
                    }
                    break;
                case 'topic_resolved': currentTopicStatus = 'resolved'; updateResolveBtn(); addMessage('system', 'Topic resolved.'); ws.send(JSON.stringify({type: 'list_topics'})); break;
                case 'topic_reopened': currentTopicStatus = 'active'; updateResolveBtn(); addMessage('system', 'Topic reopened.'); ws.send(JSON.stringify({type: 'list_topics'})); break;
                case 'topic_deleted':
                    delete topicStates[data.topic_id]; if (agentTopicId === data.topic_id) agentTopicId = null;
                    if (data.topic_id === currentTopicId) { currentTopicId = null; document.getElementById('topic-title').textContent = 'OpenPixie'; document.getElementById('topic-meta').textContent = 'Topic deleted'; clearChat(); isSending = false; updateSendButton(); hideToolConfirm(); }
                    ws.send(JSON.stringify({type: 'list_topics'})); break;
                case 'topic_ended': addMessage('system', 'This topic has ended.'); ws.send(JSON.stringify({type: 'list_topics'})); break;
                case 'config':
                    if (data.config) {
                        var c = data.config;
                        if (c.ollama_host) document.getElementById('settings-ollama-host').value = c.ollama_host;
                        if (c.ollama_model) document.getElementById('settings-ollama-model').value = c.ollama_model;
                        if (c.permission_mode) document.getElementById('settings-perm-mode').value = c.permission_mode;
                        if (c.max_context_tokens) document.getElementById('settings-max-context-tokens').value = c.max_context_tokens;
                        if (c.llm_timeout_ms) document.getElementById('settings-llm-timeout').value = c.llm_timeout_ms;
                        if (c.idle_timeout_minutes) document.getElementById('settings-idle-timeout').value = c.idle_timeout_minutes;
                    }
                    break;
                case 'config_updated':
                    if (data.result && data.result.success) {
                        var upd = data.result.updated || {};
                        if (upd.permission_mode) document.getElementById('perm-mode').value = upd.permission_mode;
                        showToast('Settings saved successfully');
                        history.back();
                    } else {
                        showToast('Failed to save: ' + ((data.result && data.result.error) || 'Unknown error'), true);
                    }
                    break;
            }
        }

        // --- Sidebar rendering ---
        function renderSidebar(topicList, channelList) {
            var grouped = {};
            (channelList || []).forEach(function(ch) { grouped[ch.name] = {info: ch, topics: []}; });
            (topicList || []).forEach(function(t) { var ch = t.channel_id || 'general'; if (!grouped[ch]) grouped[ch] = {info: {name: ch, description: ch}, topics: []}; grouped[ch].topics.push(t); });
            var container = document.getElementById('channel-list');
            container.innerHTML = '';
            Object.keys(grouped).sort().forEach(function(chName) {
                var ch = grouped[chName];
                var chDiv = document.createElement('div'); chDiv.className = 'channel';
                var header = document.createElement('div'); header.className = 'channel-header';
                header.innerHTML = '<span>' + chName + '</span><span class="arrow">&#9662;</span>';
                var topicListEl = document.createElement('div'); topicListEl.className = 'topic-list';
                ch.topics.sort(function(a, b) { var order = {active: 0, idle: 1, resolved: 2, archived: 3}; return (order[a.status] || 0) - (order[b.status] || 0); }).forEach(function(t) {
                    var item = document.createElement('div');
                    item.className = 'topic-item' + (t.id === currentTopicId ? ' active' : '') + (t.status === 'resolved' ? ' resolved' : '');
                    item.setAttribute('data-topic-id', t.id);
                    var dot = document.createElement('span');
                    var ts = getTopicState(t.id); var hasUnread = ts && ts.unread > 0;
                    dot.className = 'status-dot ' + (hasUnread ? 'unread' : (t.active ? 'active' : (t.status || 'idle')));
                    item.appendChild(dot);
                    var title = document.createElement('span'); title.className = 'topic-title-text'; title.textContent = t.title || t.id.substring(0, 8); item.appendChild(title);
                    if (t.status === 'resolved') { var check = document.createElement('span'); check.className = 'resolved-check'; check.textContent = ' \u2713'; item.appendChild(check); }
                    var del = document.createElement('span'); del.className = 'delete-btn'; del.textContent = '\u2715';
                    del.onclick = (function(tid) { return function(e) { e.stopPropagation(); deleteTopicById(tid); }; })(t.id);
                    item.appendChild(del);
                    item.onclick = function() { switchTopic(t.id); };
                    topicListEl.appendChild(item);
                });
                var collapsed = false;
                header.onclick = function() { collapsed = !collapsed; topicListEl.className = 'topic-list' + (collapsed ? ' collapsed' : ''); header.querySelector('.arrow').className = 'arrow' + (collapsed ? ' collapsed' : ''); };
                chDiv.appendChild(header); chDiv.appendChild(topicListEl); container.appendChild(chDiv);
            });
        }

        // --- Topic management ---
        function switchTopic(topicId) { if (!ws || ws.readyState !== WebSocket.OPEN) return; ws.send(JSON.stringify({type: 'switch_topic', topic_id: topicId})); }
        function clearChat() { document.getElementById('chat-area').innerHTML = ''; lastThinkingEl = null; streamingEl = null; streamingRawText = ''; lastToolStepEl = null; lastGuardianBadgeEl = null; messageIndex = 0; }

        var messageIndex = 0;
        function addMessage(role, content, topicId, fullMsg, isStreaming) {
            if (!isStreaming && role === 'assistant' && (!content || String(content).trim() === '')) return null;
            if (role === 'tool' && (!content || String(content).trim() === '') && !(fullMsg && (fullMsg.tool || fullMsg.name))) return null;
            var isUserMsg = (role === 'user');
            var div = document.createElement('div'); div.className = 'msg ' + role;
            if (isUserMsg) { div.setAttribute('data-message-index', messageIndex); }
            var ts = (fullMsg && fullMsg.timestamp) || Date.now();
            var timeEl = document.createElement('span'); timeEl.className = 'msg-time'; timeEl.textContent = formatTime(ts); div.appendChild(timeEl);
            if (isUserMsg) {
                var retryBtn = document.createElement('button'); retryBtn.className = 'retry-btn'; retryBtn.textContent = '\u21bb Retry'; retryBtn.title = 'Retry from this message';
                retryBtn.setAttribute('data-msg-index', messageIndex);
                retryBtn.onclick = function() { retryFromMessage(parseInt(this.getAttribute('data-msg-index'))); };
                div.appendChild(retryBtn);
            }
            var contentEl = document.createElement('span'); contentEl.className = 'msg-content';
            if (role === 'tool') { renderToolMessage(div, content, fullMsg); }
            else if (role === 'user' || role === 'assistant') { contentEl.className = 'msg-content md'; contentEl.innerHTML = renderMarkdown((content || '').toString()); div.appendChild(contentEl); }
            else { contentEl.textContent = (content || '').toString(); div.appendChild(contentEl); }
            document.getElementById('chat-area').appendChild(div);
            if (isUserMsg) messageIndex++;
            document.getElementById('chat-area').scrollTop = document.getElementById('chat-area').scrollHeight;
            return div;
        }

        function formatTime(ts) { var d = typeof ts === 'number' ? new Date(ts) : new Date(ts); var h = String(d.getHours()).padStart(2, '0'); var m = String(d.getMinutes()).padStart(2, '0'); var now = new Date(); if (d.toDateString() === now.toDateString()) return h + ':' + m; var month = String(d.getMonth() + 1).padStart(2, '0'); var day = String(d.getDate()).padStart(2, '0'); return month + '/' + day + ' ' + h + ':' + m; }

        function renderInlineMarkdown(text) { var h = text; h = h.replace(/`([^`\n]+?)`/g, '<code>$1</code>'); h = h.replace(/\*\*\*(.+?)\*\*\*/g, '<strong><em>$1</em></strong>'); h = h.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>'); h = h.replace(/\*(.+?)\*/g, '<em>$1</em>'); h = h.replace(/(?<!\!)\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>'); return h; }

        function renderMarkdown(text) {
            if (!text) return '';
            var html = escHtml(text);
            html = html.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#x27;/g, "'").replace(/&#x2F;/g, '/');
            var fences = [];
            html = html.replace(/```(\w*)\n([\s\S]*?)```/g, function(_, lang, code) { var i = fences.length; fences.push('<pre><code class="lang-' + lang + '">' + code.replace(/</g, '&lt;').replace(/>/g, '&gt;') + '</code></pre>'); return '\x00FENCE' + i + '\x00'; });
            var tables = [];
            html = html.replace(/(?:^\|.+\|$\n?)+/gm, function(block) {
                var rows = block.trim().split('\n').filter(function(r) { return r.trim().length > 0; }); var parsed = [];
                for (var ri = 0; ri < rows.length; ri++) { var cells = rows[ri].split('|').slice(1, -1).map(function(c) { return c.trim(); }); if (cells.length > 0) parsed.push(cells); }
                if (parsed.length === 0) return block;
                var sepIdx = -1;
                for (var si = 0; si < parsed.length; si++) { if (parsed[si].every(function(c) { return /^[\s:-]+$/.test(c); })) { sepIdx = si; break; } }
                var ti = tables.length; var thtml = '<table>';
                var startRow = (sepIdx === 0) ? 1 : 0;
                if (sepIdx >= 0 && startRow < parsed.length) { thtml += '<thead><tr>'; for (var ci = 0; ci < parsed[startRow].length; ci++) thtml += '<th>' + renderInlineMarkdown(parsed[startRow][ci]) + '</th>'; thtml += '</tr></thead>'; }
                var tbodyRows = parsed.slice(sepIdx >= 0 ? sepIdx + 1 : (parsed.length > 1 ? 1 : 0));
                if (tbodyRows.length > 0) { thtml += '<tbody>'; for (var tri = 0; tri < tbodyRows.length; tri++) { thtml += '<tr>'; for (var tdi = 0; tdi < tbodyRows[tri].length; tdi++) thtml += '<td>' + renderInlineMarkdown(tbodyRows[tri][tdi]) + '</td>'; thtml += '</tr>'; } thtml += '</tbody>'; }
                else if (sepIdx < 0 && parsed.length > 0) { thtml += '<tbody>'; for (var tri2 = 0; tri2 < parsed.length; tri2++) { thtml += '<tr>'; for (var tdi2 = 0; tdi2 < parsed[tri2].length; tdi2++) thtml += '<td>' + renderInlineMarkdown(parsed[tri2][tdi2]) + '</td>'; thtml += '</tr>'; } thtml += '</tbody>'; }
                thtml += '</table>'; tables.push(thtml); return '\x00TABLE' + ti + '\x00';
            });
            html = html.replace(/`([^`\n]+?)`/g, '<code>$1</code>');
            html = html.replace(/\*\*\*(.+?)\*\*\*/g, '<strong><em>$1</em></strong>');
            html = html.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
            html = html.replace(/\*(.+?)\*/g, '<em>$1</em>');
            html = html.replace(/(?<!\!)\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
            var lines = html.split('\n');
            var blocks = [];
            var i = 0;
            while (i < lines.length) {
                var line = lines[i];
                if (/^#### (.+)$/.test(line)) { blocks.push({type: 'h4', content: line.replace(/^#### (.+)$/, '$1')}); i++; }
                else if (/^### (.+)$/.test(line)) { blocks.push({type: 'h3', content: line.replace(/^### (.+)$/, '$1')}); i++; }
                else if (/^## (.+)$/.test(line)) { blocks.push({type: 'h2', content: line.replace(/^## (.+)$/, '$1')}); i++; }
                else if (/^# (.+)$/.test(line)) { blocks.push({type: 'h1', content: line.replace(/^# (.+)$/, '$1')}); i++; }
                else if (/^---$/.test(line.trim())) { blocks.push({type: 'hr'}); i++; }
                else if (/^> ?(.*)$/.test(line)) { var bqLines = []; while (i < lines.length && /^> ?(.*)$/.test(lines[i])) { bqLines.push(lines[i].replace(/^> ?(.*)$/, '$1')); i++; } blocks.push({type: 'blockquote', content: bqLines.join('\n')}); }
                else if (/^[-*] /.test(line)) { var ulItems = []; while (i < lines.length && /^[-*] (.+)$/.test(lines[i])) { ulItems.push(lines[i].replace(/^[-*] (.+)$/, '$1')); i++; } blocks.push({type: 'ul', items: ulItems}); }
                else if (/^\d+\. /.test(line)) { var olItems = []; while (i < lines.length && /^\d+\. (.+)$/.test(lines[i])) { olItems.push(lines[i].replace(/^\d+\. (.+)$/, '$1')); i++; } blocks.push({type: 'ol', items: olItems}); }
                else if (/^\x00(FENCE|TABLE)/.test(line)) { blocks.push({type: 'raw', content: line}); i++; }
                else if (line.trim() === '') { blocks.push({type: 'break'}); i++; }
                else { var paraLines = []; while (i < lines.length && lines[i].trim() !== '' && !/^#{1,4} |^[-*] |^\d+\. |^> |^---$|^\x00(FENCE|TABLE)/.test(lines[i])) { paraLines.push(lines[i]); i++; } if (paraLines.length > 0) blocks.push({type: 'para', lines: paraLines}); }
            }
            var result = '';
            for (var bi = 0; bi < blocks.length; bi++) {
                var b = blocks[bi];
                if (b.type === 'h1') result += '<h1>' + renderInlineMarkdown(b.content) + '</h1>';
                else if (b.type === 'h2') result += '<h2>' + renderInlineMarkdown(b.content) + '</h2>';
                else if (b.type === 'h3') result += '<h3>' + renderInlineMarkdown(b.content) + '</h3>';
                else if (b.type === 'h4') result += '<h4>' + renderInlineMarkdown(b.content) + '</h4>';
                else if (b.type === 'hr') result += '<hr>';
                else if (b.type === 'blockquote') result += '<blockquote>' + renderMarkdown(b.content) + '</blockquote>';
                else if (b.type === 'ul') { result += '<ul>'; for (var ui = 0; ui < b.items.length; ui++) result += '<li>' + renderInlineMarkdown(b.items[ui]) + '</li>'; result += '</ul>'; }
                else if (b.type === 'ol') { result += '<ol>'; for (var oi = 0; oi < b.items.length; oi++) result += '<li>' + renderInlineMarkdown(b.items[oi]) + '</li>'; result += '</ol>'; }
                else if (b.type === 'para') result += '<p>' + b.lines.map(function(l) { return renderInlineMarkdown(l); }).join('<br>') + '</p>';
                else if (b.type === 'raw') result += b.content;
                else if (b.type === 'break' && bi > 0 && bi < blocks.length - 1 && blocks[bi - 1].type !== 'break' && blocks[bi + 1].type !== 'break') { /* skip, paragraphs already separated */ }
            }
            for (var fi = 0; fi < fences.length; fi++) result = result.replace('\x00FENCE' + fi + '\x00', fences[fi]);
            for (var ti2 = 0; ti2 < tables.length; ti2++) result = result.replace('\x00TABLE' + ti2 + '\x00', tables[ti2]);
            return result;
        }

        function removeThinking() { if (lastThinkingEl && lastThinkingEl.parentNode) lastThinkingEl.parentNode.removeChild(lastThinkingEl); lastThinkingEl = null; }
        function showBanner(msg) { var el = document.getElementById('connection-banner'); if (!el) { el = document.createElement('div'); el.id = 'connection-banner'; el.style.cssText = 'position:fixed;top:0;left:0;right:0;background:#e81123;color:#fff;text-align:center;padding:8px;font-size:13px;z-index:999;'; document.body.appendChild(el); } el.textContent = msg; el.style.display = 'block'; }
        function hideBanner() { var el = document.getElementById('connection-banner'); if (el) el.style.display = 'none'; }

        function showToolConfirm(tool, args, reason) {
            currentToolConfirmData = {tool: tool, args: args, reason: reason}; hideToolConfirm();
            var div = document.createElement('div'); div.className = 'msg tool-confirm'; div.id = 'tool-confirm-bar';
            var timeEl = document.createElement('span'); timeEl.className = 'msg-time'; timeEl.textContent = formatTime(Date.now()); div.appendChild(timeEl);
            var header = document.createElement('div'); header.className = 'confirm-header'; header.textContent = 'Approval Required: ' + getToolLabel(tool); div.appendChild(header);
            if (reason) { var reasonEl = document.createElement('div'); reasonEl.className = 'confirm-reason'; reasonEl.textContent = typeof reason === 'object' ? JSON.stringify(reason) : String(reason); div.appendChild(reasonEl); }
            if (args && typeof args === 'object' && Object.keys(args).length > 0) { var argsDiv = document.createElement('div'); argsDiv.className = 'confirm-args'; argsDiv.innerHTML = formatToolArgs(args); div.appendChild(argsDiv); }
            var actions = document.createElement('div'); actions.className = 'confirm-actions';
            var allowBtn = document.createElement('button'); allowBtn.className = 'btn-safe'; allowBtn.textContent = 'Allow'; allowBtn.style.cssText = 'padding:6px 16px;border:none;cursor:pointer;font-weight:600;font-size:13px;'; allowBtn.onclick = approveTool;
            var denyBtn = document.createElement('button'); denyBtn.className = 'btn-danger'; denyBtn.textContent = 'Deny'; denyBtn.style.cssText = 'padding:6px 16px;border:none;cursor:pointer;font-weight:600;font-size:13px;'; denyBtn.onclick = denyTool;
            actions.appendChild(allowBtn); actions.appendChild(denyBtn); div.appendChild(actions);
            document.getElementById('chat-area').appendChild(div); document.getElementById('chat-area').scrollTop = document.getElementById('chat-area').scrollHeight;
        }
        function hideToolConfirm() { currentToolConfirmData = null; var el = document.getElementById('tool-confirm-bar'); if (el && el.parentNode) el.parentNode.removeChild(el); }
        function approveTool() { if (!ws || ws.readyState !== WebSocket.OPEN) return; ws.send(JSON.stringify({type: 'tool_confirm', approved: true})); if (agentTopicId) { getTopicState(agentTopicId).hasToolConfirm = false; getTopicState(agentTopicId).toolConfirmData = null; } hideToolConfirm(); }
        function denyTool() { if (!ws || ws.readyState !== WebSocket.OPEN) return; ws.send(JSON.stringify({type: 'tool_confirm', approved: false})); if (agentTopicId) { getTopicState(agentTopicId).hasToolConfirm = false; getTopicState(agentTopicId).toolConfirmData = null; } hideToolConfirm(); }

        function escHtml(s) { var d = document.createElement('div'); d.textContent = String(s); return d.innerHTML; }
        function formatToolArgs(args) {
            if (!args || typeof args === 'string') return escHtml(args || '');
            if (typeof args !== 'object') return escHtml(String(args));
            var entries = Object.entries(args); if (entries.length === 0) return '';
            return entries.map(function(kv) { var val = typeof kv[1] === 'object' ? JSON.stringify(kv[1]) : String(kv[1]); var shortVal = val.length > 300 ? val.substring(0, 300) + '...' : val; return '<div class="tool-kv"><span class="tool-kv-key">' + escHtml(kv[0]) + '</span><span class="tool-kv-val">' + escHtml(shortVal) + '</span></div>'; }).join('');
        }
        var TOOL_LABELS = { 'read_file': 'Read File', 'write_file': 'Write File', 'edit_file': 'Edit File', 'list_files': 'List Files', 'file_exists': 'File Exists', 'create_directory': 'Create Directory', 'run_command': 'Run Command', 'git_status': 'Git Status', 'git_diff': 'Git Diff', 'git_add': 'Git Add', 'git_commit': 'Git Commit', 'git_log': 'Git Log', 'search_memories': 'Search Memories', 'search': 'Search', 'save_snapshot': 'Save Snapshot', 'list_snapshots': 'List Snapshots', 'load_snapshot': 'Load Snapshot', 'compile_and_reload': 'Compile & Reload', 'reload_module': 'Reload Module', 'get_self_modules': 'Loaded Modules', 'analyze_self': 'Self Analysis', 'get_performance_trend': 'Performance Trend', 'get_improvements': 'Improvements', 'propose_soul_edit': 'Propose Soul Edit', 'get_soul_proposal': 'Soul Proposal', 'apply_soul_proposal': 'Apply Soul Edit', 'reject_soul_proposal': 'Reject Soul Edit', 'ask_user': 'Ask User', 'web_search': 'Web Search', 'web_fetch': 'Web Fetch', 'sync_export': 'Sync Export', 'sync_import': 'Sync Import', 'register_tool': 'Register Tool', 'unregister_tool': 'Unregister Tool' };
        function getToolLabel(name) { if (!name) return 'Tool'; return TOOL_LABELS[name.toLowerCase()] || TOOL_LABELS[name] || name.replace(/_/g, ' ').replace(/\b\w/g, function(c) { return c.toUpperCase(); }); }

        function renderToolMessage(div, content, fullMsg) {
            var data; try { data = typeof content === 'string' ? JSON.parse(content) : content; } catch(_) { div.textContent = String(content || ''); return; }
            try {
                var toolName = (fullMsg && fullMsg.name) || data.tool || data.name;
                var args = (fullMsg && fullMsg.args) || data.args || data.arguments;
                var isSuccess = data.success === true || data.success === 'true';
                var isError = data.error || data.success === false || data.success === 'false';
                var header = document.createElement('div'); header.className = 'tool-call-header'; header.textContent = getToolLabel(toolName); div.appendChild(header);
                if (args && typeof args === 'object' && Object.keys(args).length > 0) { var argsDiv = document.createElement('div'); argsDiv.className = 'tool-call-args'; argsDiv.innerHTML = formatToolArgs(args); div.appendChild(argsDiv); }
                var resultDiv = document.createElement('div'); resultDiv.className = 'tool-call-result';
                if (isError) { resultDiv.innerHTML = '<span class="tool-result-err">Error: ' + escHtml(typeof data.error === 'object' ? JSON.stringify(data.error) : (data.error || 'Unknown error')) + '</span>'; }
                else if (isSuccess) { var summary = ''; if (data.output) summary = typeof data.output === 'string' ? data.output : JSON.stringify(data.output); else if (data.result) summary = typeof data.result === 'string' ? data.result : JSON.stringify(data.result); else if (data.content) summary = typeof data.content === 'string' ? data.content : JSON.stringify(data.content); if (summary.length > 500) summary = summary.substring(0, 500) + '...'; resultDiv.innerHTML = '<span class="tool-result-ok">' + (summary ? escHtml(summary) : 'Success') + '</span>'; }
                else { var rest = {}; for (var k in data) { if (!['tool', 'name', 'args', 'arguments', 'success', 'error', 'output', 'result', 'content'].includes(k)) rest[k] = data[k]; } if (Object.keys(rest).length > 0) resultDiv.innerHTML = formatToolArgs(rest); }
                if (resultDiv.innerHTML) div.appendChild(resultDiv);
            } catch (e) { console.error('Tool message render error:', e); var errSpan = document.createElement('span'); errSpan.className = 'tool-result-err'; errSpan.textContent = '[rendering failed: ' + String(e).substring(0, 200) + ']'; div.appendChild(errSpan); }
        }

        var lastToolStepEl = null, lastGuardianBadgeEl = null;
        function addGuardianMessage(toolName, status, reason, args) {
            var statusLabel = status === 'checking' ? 'Checking\u2026' : status === 'passed' ? 'Passed' : status === 'warned' ? 'Warning' : status === 'rejected' ? 'Rejected' : status;
            var statusIcon = status === 'checking' ? '\uD83D\uDD0D' : status === 'passed' ? '\u2705' : status === 'warned' ? '\u26A0\uFE0F' : status === 'rejected' ? '\u274C' : '\uD83D\uDD0D';
            var toolLabel = getToolLabel(toolName);
            var div = document.createElement('div');
            div.className = 'msg guardian guardian-' + status;
            var content = statusIcon + ' **Guardian ' + statusLabel + ':** ' + escHtml(toolLabel);
            if (args) {
                var argsStr = formatToolArgs(args);
                if (argsStr) content += ' \u2014 ' + argsStr;
            }
            if (reason && (status === 'rejected' || status === 'warned')) {
                var reasonText = typeof reason === 'string' ? reason : typeof reason === 'object' ? (reason.message || reason.error || JSON.stringify(reason)) : String(reason);
                content += '\n\u2014 ' + escHtml(reasonText);
            }
            var contentSpan = document.createElement('span');
            contentSpan.className = 'msg-content md';
            contentSpan.innerHTML = renderMarkdown(content);
            div.appendChild(contentSpan);
            var tsEl = document.createElement('span');
            tsEl.className = 'msg-time';
            tsEl.textContent = formatTime(Date.now());
            div.appendChild(tsEl);
            document.getElementById('chat-area').appendChild(div);
            document.getElementById('chat-area').scrollTop = document.getElementById('chat-area').scrollHeight;
            lastGuardianBadgeEl = div;
            return div;
        }
        function showToolStep(tool, args, status) { if (lastToolStepEl && lastToolStepEl.dataset.tool === tool && lastToolStepEl.dataset.status === 'running') { lastToolStepEl.querySelector('.tool-status').textContent = status; lastToolStepEl.querySelector('.tool-status').className = 'tool-status ' + status; lastToolStepEl.dataset.status = status; lastToolStepEl = null; return; } var div = document.createElement('div'); div.className = 'tool-step'; div.dataset.tool = tool; div.dataset.status = status; var argsHtml = formatToolArgs(args); div.innerHTML = '<span class="tool-name">' + escHtml(getToolLabel(tool)) + '</span>' + '<span class="tool-args">' + (argsHtml || '') + '</span>' + '<span class="tool-status ' + escHtml(status) + '">' + escHtml(status) + '</span>'; document.getElementById('chat-area').appendChild(div); document.getElementById('chat-area').scrollTop = document.getElementById('chat-area').scrollHeight; if (status === 'running') lastToolStepEl = div; }
        function setPermMode(mode) { if (!ws || ws.readyState !== WebSocket.OPEN) return; ws.send(JSON.stringify({type: 'set_permission_mode', mode: mode})); }

        function showAskUserModal(tool, question, context) {
            hideAskUserModal();
            var overlay = document.createElement('div'); overlay.className = 'ask-user-modal'; overlay.id = 'ask-user-modal';
            var modal = document.createElement('div'); modal.className = 'modal';
            modal.innerHTML = '<h3>Question</h3><div class="ask-context">' + escHtml(context || '') + '</div><p style="color:#555;font-size:13px;margin-bottom:16px;line-height:1.4;">' + escHtml(question) + '</p><textarea id="ask-user-input" placeholder="Type your answer..." rows="3"></textarea><div class="btn-row" style="margin-top:16px;"><button class="btn-submit" id="ask-user-submit">Send</button></div>';
            overlay.appendChild(modal); document.body.appendChild(overlay);
            var input = document.getElementById('ask-user-input'); var submitBtn = document.getElementById('ask-user-submit'); input.focus();
            submitBtn.addEventListener('click', function() { var answer = input.value.trim(); if (!answer) return; if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({type: 'ask_user_response', response: answer})); hideAskUserModal(); });
            input.addEventListener('keydown', function(e) { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submitBtn.click(); } });
        }
        function hideAskUserModal() { var el = document.getElementById('ask-user-modal'); if (el) el.remove(); }

        function showRefreshBanner() { var banner = document.getElementById('refresh-banner'); if (banner) return; banner = document.createElement('div'); banner.id = 'refresh-banner'; banner.className = 'refresh-banner'; banner.innerHTML = 'Dashboard was modified. <button onclick="location.reload()">Refresh</button>'; document.body.appendChild(banner); }
        function updateResolveBtn() {
            var resolveBtn = document.getElementById('resolve-btn'); var reopenBtn = document.getElementById('reopen-btn'); var deleteBtn = document.getElementById('delete-btn');
            if (currentTopicId && currentTopicStatus === 'resolved') { resolveBtn.style.display = 'none'; reopenBtn.style.display = 'inline-block'; deleteBtn.style.display = 'inline-block'; }
            else if (currentTopicId) { resolveBtn.style.display = 'inline-block'; reopenBtn.style.display = 'none'; deleteBtn.style.display = 'inline-block'; }
            else { resolveBtn.style.display = 'none'; reopenBtn.style.display = 'none'; deleteBtn.style.display = 'none'; }
        }
        function resolveCurrentTopic() { if (!currentTopicId || !ws || ws.readyState !== WebSocket.OPEN) return; ws.send(JSON.stringify({type: 'resolve_topic', topic_id: currentTopicId})); }
        function reopenCurrentTopic() { if (!currentTopicId || !ws || ws.readyState !== WebSocket.OPEN) return; ws.send(JSON.stringify({type: 'reopen_topic', topic_id: currentTopicId})); }
        function deleteCurrentTopic() { if (!currentTopicId || !ws || ws.readyState !== WebSocket.OPEN) return; if (!confirm('Delete this topic and all its messages? This cannot be undone.')) return; ws.send(JSON.stringify({type: 'delete_topic', topic_id: currentTopicId})); }
        function deleteTopicById(topicId) { if (!ws || ws.readyState !== WebSocket.OPEN) return; if (!confirm('Delete this topic? This cannot be undone.')) return; ws.send(JSON.stringify({type: 'delete_topic', topic_id: topicId})); }
        function updateSendButton() { var btn = document.getElementById('send-btn'); var intBtn = document.getElementById('interrupt-btn'); if (isSending) { btn.disabled = true; btn.textContent = 'Thinking...'; intBtn.style.display = 'inline-block'; } else { btn.disabled = false; btn.textContent = 'Send'; intBtn.style.display = 'none'; } }
        function interruptAgent() { if (!ws || ws.readyState !== WebSocket.OPEN) return; ws.send(JSON.stringify({type: 'interrupt'})); if (agentTopicId) { getTopicState(agentTopicId).isSending = false; getTopicState(agentTopicId).hasToolConfirm = false; getTopicState(agentTopicId).toolConfirmData = null; } agentTopicId = null; isSending = false; finalizeStreaming(); removeThinking(); updateSendButton(); hideToolConfirm(); addMessage('system', 'Interrupted.'); }
        function sendMessage() { var input = document.getElementById('message-input'); var text = input.value.trim(); if (!text || !ws || ws.readyState !== WebSocket.OPEN) return; if (!currentTopicId) { addMessage('system', 'No active topic. Create or select one first.'); return; } addMessage('user', text); ws.send(JSON.stringify({type: 'chat', content: text})); input.value = ''; isSending = true; agentTopicId = currentTopicId; updateSendButton(); }
        function retryFromMessage(messageIndex) { if (!ws || ws.readyState !== WebSocket.OPEN) return; if (!currentTopicId) return; if (isSending) { showToast('Cannot retry while agent is running', true); return; } if (!confirm('Retry from this message? All messages after it will be removed.')) return; ws.send(JSON.stringify({type: 'retry_from', message_index: messageIndex})); isSending = true; agentTopicId = currentTopicId; updateSendButton(); }
        function openNewTopicModal() { document.getElementById('overlay-modal').style.display = 'block'; var titleInput = document.getElementById('new-topic-title'); titleInput.value = ''; titleInput.focus(); }
        function closeModal() { document.getElementById('overlay-modal').style.display = 'none'; }
        function createNewTopic() { var title = document.getElementById('new-topic-title').value.trim() || 'Untitled'; var channel = document.getElementById('new-topic-channel').value; if (!ws || ws.readyState !== WebSocket.OPEN) return; ws.send(JSON.stringify({type: 'new_topic', title: title, channel_id: channel})); closeModal(); }
        function showToast(message, isError) { var toast = document.getElementById('toast'); toast.textContent = message; toast.className = 'toast' + (isError ? ' error' : ''); toast.classList.add('show'); clearTimeout(toast._timer); toast._timer = setTimeout(function() { toast.classList.remove('show'); }, 3000); }
        function switchSettingsTab(tabName) {
            document.querySelectorAll('.settings-tab').forEach(function(t) { t.classList.remove('active'); });
            document.querySelectorAll('.settings-tab-content').forEach(function(c) { c.classList.remove('active'); });
            var tabBtn = document.querySelector('.settings-tab[onclick*="' + tabName + '"]');
            if (tabBtn) tabBtn.classList.add('active');
            var tabContent = document.getElementById('settings-tab-' + tabName);
            if (tabContent) tabContent.classList.add('active');
        }
        function loadSoulEditor() {
            authFetch('/api/v1/pixie-data/soul').then(function(r) { return r.json(); }).then(function(data) {
                var editor = document.getElementById('settings-soul-editor');
                if (editor) editor.value = data.content || '';
            }).catch(function() {});
        }
        function saveSoul() {
            var content = document.getElementById('settings-soul-editor').value;
            authFetch('/api/v1/pixie-data/soul', {
                method: 'PUT',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({content: content})
            }).then(function(r) { return r.json(); }).then(function(data) {
                if (data.success) { showToast('SOUL.md saved'); }
                else { showToast('Failed: ' + (data.error || 'Unknown error'), true); }
            }).catch(function(err) { showToast('Failed: ' + err.message, true); });
        }
        function loadRawConfig() {
            authFetch('/api/v1/pixie-data/config').then(function(r) { return r.json(); }).then(function(data) {
                var editor = document.getElementById('settings-raw-config');
                if (editor) {
                    try { editor.value = JSON.stringify(JSON.parse(data.content || '{}'), null, 2); } catch(_) { editor.value = data.content || '{}'; }
                }
            }).catch(function() {});
        }
        function saveRawConfig() {
            var editor = document.getElementById('settings-raw-config');
            var content = editor.value;
            try { JSON.parse(content); } catch(e) { showToast('Invalid JSON: ' + e.message, true); return; }
            authFetch('/api/v1/pixie-data/config', {
                method: 'PUT',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({content: content})
            }).then(function(r) { return r.json(); }).then(function(data) {
                if (data.success) { showToast('config.json saved — reload for changes to take effect'); }
                else { showToast('Failed: ' + (data.error || 'Unknown error'), true); }
            }).catch(function(err) { showToast('Failed: ' + err.message, true); });
        }
        function loadApiKeyDisplay() {
            authFetch('/api/v1/pixie-data/api_key').then(function(r) { return r.json(); }).then(function(data) {
                var input = document.getElementById('settings-apikey-value');
                if (input) input.value = data.content || '';
            }).catch(function() {});
        }
        function toggleApiKeyVisibility() {
            var input = document.getElementById('settings-apikey-value');
            input.type = input.type === 'password' ? 'text' : 'password';
        }
        function copyApiKey() {
            var input = document.getElementById('settings-apikey-value');
            if (!input.value) return;
            navigator.clipboard.writeText(input.value).then(function() { showToast('Copied to clipboard'); }).catch(function() { input.type = 'text'; input.select(); document.execCommand('copy'); input.type = 'password'; showToast('Copied'); });
        }
        function regenerateApiKey() {
            if (!confirm('Regenerate API key? The current key will stop working immediately.')) return;
            authFetch('/api/v1/pixie-data/api_key', {
                method: 'PUT',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({action: 'regenerate'})
            }).then(function(r) { return r.json(); }).then(function(data) {
                if (data.success && data.new_key) {
                    document.getElementById('settings-apikey-value').value = data.new_key;
                    document.getElementById('settings-apikey-value').type = 'text';
                    showToast('New API key generated — copy it now!');
                } else { showToast('Failed: ' + (data.error || 'Unknown error'), true); }
            }).catch(function(err) { showToast('Failed: ' + err.message, true); });
        }
        var skillsEditingName = null;
        function loadSkillsList() {
            authFetch('/api/v1/skills').then(function(r) { return r.json(); }).then(function(data) {
                var container = document.getElementById('skills-list-container');
                if (!container) return;
                container.innerHTML = '';
                var skills = data.skills || [];
                if (skills.length === 0) {
                    container.innerHTML = '<div style="padding:16px;color:#888;">No skills found. Create one to get started.</div>';
                    return;
                }
                skills.forEach(function(sk) {
                    var card = document.createElement('div'); card.className = 'skill-card';
                    var info = document.createElement('div'); info.className = 'skill-info';
                    var nameEl = document.createElement('span'); nameEl.className = 'skill-card-name'; nameEl.textContent = sk.name;
                    nameEl.onclick = function() { editSkill(sk.name); };
                    info.appendChild(nameEl);
                    if (sk.always) { var badge = document.createElement('span'); badge.className = 'skill-badge'; badge.textContent = 'always'; info.appendChild(badge); }
                    if (sk.description) { var descEl = document.createElement('div'); descEl.className = 'skill-card-desc'; descEl.textContent = sk.description; info.appendChild(descEl); }
                    card.appendChild(info);
                    var acts = document.createElement('div'); acts.className = 'skill-actions';
                    var editBtn = document.createElement('button'); editBtn.textContent = 'Edit'; editBtn.onclick = function() { editSkill(sk.name); };
                    var delBtn = document.createElement('button'); delBtn.className = 'btn-skill-del'; delBtn.textContent = 'Delete'; delBtn.onclick = function() { deleteSkill(sk.name); };
                    acts.appendChild(editBtn); acts.appendChild(delBtn);
                    card.appendChild(acts);
                    container.appendChild(card);
                });
            }).catch(function() {});
        }
        function showNewSkillForm() {
            skillsEditingName = null;
            document.getElementById('skill-editor-name').value = '';
            document.getElementById('skill-editor-name').disabled = false;
            document.getElementById('skill-editor-content').value = '---\ndescription: \nalways: false\n---\n\n# New Skill\n\n';
            document.getElementById('skill-delete-btn').style.display = 'none';
            document.getElementById('skill-editor-panel').style.display = 'block';
            document.getElementById('skill-editor-name').focus();
        }
        function editSkill(name) {
            skillsEditingName = name;
            document.getElementById('skill-editor-name').value = name;
            document.getElementById('skill-editor-name').disabled = true;
            document.getElementById('skill-delete-btn').style.display = 'inline-block';
            openpixie_skills_load(name);
        }
        function openpixie_skills_load(name) {
            authFetch('/api/v1/skills', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({action: 'load', name: name})
            }).then(function(r) { if (r.ok) return r.json(); return r.json().then(function(d) { throw new Error(d.error || 'Load failed'); }); }).then(function(data) {
                if (data.content !== undefined) {
                    document.getElementById('skill-editor-content').value = data.content;
                    document.getElementById('skill-editor-panel').style.display = 'block';
                } else { showToast('Failed to load skill content', true); }
            }).catch(function(err) { showToast(err.message, true); });
        }
        function closeSkillEditor() {
            document.getElementById('skill-editor-panel').style.display = 'none';
            skillsEditingName = null;
        }
        function saveSkillEditor() {
            var name = document.getElementById('skill-editor-name').value.trim();
            var content = document.getElementById('skill-editor-content').value;
            if (!name) { showToast('Skill name is required', true); return; }
            if (!/^[a-z0-9_-]+$/.test(name)) { showToast('Skill name must be lowercase with hyphens only', true); return; }
            var action = skillsEditingName ? 'update' : 'create';
            authFetch('/api/v1/skills', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({action: action, name: name, content: content})
            }).then(function(r) { return r.json(); }).then(function(data) {
                if (data.success) {
                    showToast('Skill saved');
                    skillsEditingName = name;
                    document.getElementById('skill-editor-name').disabled = true;
                    document.getElementById('skill-delete-btn').style.display = 'inline-block';
                    loadSkillsList();
                } else if (data.error === 'already_exists') {
                    showToast('A skill with this name already exists', true);
                } else {
                    showToast('Failed: ' + (data.error || 'Unknown error'), true);
                }
            }).catch(function(err) { showToast('Failed: ' + err.message, true); });
        }
        function deleteSkill(name) {
            if (!confirm('Delete skill "' + name + '"? This cannot be undone.')) return;
            authFetch('/api/v1/skills', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({action: 'delete', name: name})
            }).then(function(r) { return r.json(); }).then(function(data) {
                if (data.success) { showToast('Skill deleted'); closeSkillEditor(); loadSkillsList(); }
                else { showToast('Failed: ' + (data.error || 'Unknown error'), true); }
            }).catch(function(err) { showToast('Failed: ' + err.message, true); });
        }
        function deleteSkillEditor() {
            if (skillsEditingName) deleteSkill(skillsEditingName);
        }
        function loadToolsList() {
            authFetch('/api/v1/tools').then(function(r) { return r.json(); }).then(function(data) {
                var container = document.getElementById('tools-list-container');
                if (!container) return;
                container.innerHTML = '';
                var tools = data.tools || [];
                var mode = data.mode || 'ask';
                var categories = {};
                tools.forEach(function(t) {
                    var cat = t.category || 'general';
                    if (!categories[cat]) categories[cat] = [];
                    categories[cat].push(t);
                });
                var catOrder = ['file', 'git', 'command', 'search', 'memory', 'skills', 'interaction', 'self-modification', 'metacognitive', 'sync', 'system', 'general'];
                catOrder.forEach(function(cat) {
                    if (!categories[cat]) return;
                    var div = document.createElement('div'); div.className = 'tool-category';
                    var title = document.createElement('div'); title.className = 'tool-category-title';
                    title.textContent = cat.replace(/-/g, ' ').replace(/\b\w/g, function(c) { return c.toUpperCase(); });
                    div.appendChild(title);
                    categories[cat].forEach(function(t) {
                        var card = document.createElement('div'); card.className = 'tool-card';
                        var info = document.createElement('div'); info.className = 'tool-info';
                        var name = document.createElement('div'); name.className = 'tool-name'; name.textContent = t.name;
                        info.appendChild(name);
                        if (t.description) { var desc = document.createElement('div'); desc.className = 'tool-desc'; desc.textContent = t.description; info.appendChild(desc); }
                        if (t.required && t.required.length > 0) {
                            var req = document.createElement('div'); req.className = 'tool-desc'; req.style.fontFamily = 'monospace'; req.textContent = 'Required: ' + t.required.join(', ');
                            info.appendChild(req);
                        }
                        card.appendChild(info);
                        var badge = document.createElement('span'); badge.className = 'tool-perm tool-perm-' + t.permission;
                        badge.textContent = t.permission;
                        card.appendChild(badge);
                        div.appendChild(card);
                    });
                    container.appendChild(div);
                });
                Object.keys(categories).forEach(function(cat) {
                    if (catOrder.indexOf(cat) === -1) {
                        var div = document.createElement('div'); div.className = 'tool-category';
                        var title = document.createElement('div'); title.className = 'tool-category-title';
                        title.textContent = cat.replace(/-/g, ' ').replace(/\b\w/g, function(c) { return c.toUpperCase(); });
                        div.appendChild(title);
                        categories[cat].forEach(function(t) {
                            var card = document.createElement('div'); card.className = 'tool-card';
                            var info = document.createElement('div'); info.className = 'tool-info';
                            var name = document.createElement('div'); name.className = 'tool-name'; name.textContent = t.name;
                            info.appendChild(name);
                            if (t.description) { var desc = document.createElement('div'); desc.className = 'tool-desc'; desc.textContent = t.description; info.appendChild(desc); }
                            card.appendChild(info);
                            var badge = document.createElement('span'); badge.className = 'tool-perm tool-perm-' + t.permission;
                            badge.textContent = t.permission;
                            card.appendChild(badge);
                            div.appendChild(card);
                        });
                        container.appendChild(div);
                    }
                });
            }).catch(function() {});
        }
        function loadGitSettings() {
            authFetch('/api/v1/pixie-data/git_remote').then(function(r) { return r.json(); }).then(function(data) {
                var el = document.getElementById('settings-git-remote');
                if (el) el.value = (data.content || '').trim();
            }).catch(function() {});
            authFetch('/api/v1/pixie-data/git_branch').then(function(r) { return r.json(); }).then(function(data) {
                var el = document.getElementById('settings-git-branch');
                if (el) el.value = (data.content || '').trim() || 'develop';
            }).catch(function() {});
            authFetch('/api/v1/pixie-data/git_name').then(function(r) { return r.json(); }).then(function(data) {
                var el = document.getElementById('settings-git-name');
                if (el) el.value = (data.content || '').trim() || 'OpenPixie';
            }).catch(function() {});
            authFetch('/api/v1/pixie-data/git_email').then(function(r) { return r.json(); }).then(function(data) {
                var el = document.getElementById('settings-git-email');
                if (el) el.value = (data.content || '').trim() || 'pixie@openpixie';
            }).catch(function() {});
            authFetch('/api/v1/pixie-data/ssh_key').then(function(r) { return r.json(); }).then(function(data) {
                var el = document.getElementById('settings-ssh-key');
                if (el) el.value = data.content || '';
            }).catch(function() {});
            authFetch('/api/v1/pixie-data/known_hosts').then(function(r) { return r.json(); }).then(function(data) {
                var el = document.getElementById('settings-known-hosts');
                if (el) el.value = data.content || '';
            }).catch(function() {});
        }
        function saveGitSettings() {
            var remote = document.getElementById('settings-git-remote').value.trim();
            var branch = document.getElementById('settings-git-branch').value.trim();
            var sshKey = document.getElementById('settings-ssh-key').value;
            var knownHosts = document.getElementById('settings-known-hosts').value;
            var promises = [];
            if (remote) {
                promises.push(authFetch('/api/v1/pixie-data/git_remote', {
                    method: 'PUT', headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({content: remote + '\n'})
                }).then(function(r) { return r.json(); }));
            }
            if (branch) {
                promises.push(authFetch('/api/v1/pixie-data/git_branch', {
                    method: 'PUT', headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({content: branch + '\n'})
                }).then(function(r) { return r.json(); }));
            }
            var gitName = document.getElementById('settings-git-name').value.trim();
            var gitEmail = document.getElementById('settings-git-email').value.trim();
            if (gitName) {
                promises.push(authFetch('/api/v1/pixie-data/git_name', {
                    method: 'PUT', headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({content: gitName + '\n'})
                }).then(function(r) { return r.json(); }));
            }
            if (gitEmail) {
                promises.push(authFetch('/api/v1/pixie-data/git_email', {
                    method: 'PUT', headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({content: gitEmail + '\n'})
                }).then(function(r) { return r.json(); }));
            }
            if (sshKey) {
                promises.push(authFetch('/api/v1/pixie-data/ssh_key', {
                    method: 'PUT', headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({content: sshKey.endsWith('\n') ? sshKey : sshKey + '\n'})
                }).then(function(r) { return r.json(); }));
            }
            if (knownHosts) {
                promises.push(authFetch('/api/v1/pixie-data/known_hosts', {
                    method: 'PUT', headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({content: knownHosts.endsWith('\n') ? knownHosts : knownHosts + '\n'})
                }).then(function(r) { return r.json(); }));
            }
            Promise.all(promises).then(function(results) {
                var failed = results.find(function(d) { return !d.success; });
                if (failed) { showToast('Failed: ' + (failed.error || 'Unknown error'), true); }
                else { showToast('Git settings saved'); }
            }).catch(function(err) { showToast('Failed: ' + err.message, true); });
        }
        function testGitConnection() {
            var resultEl = document.getElementById('git-test-result');
            resultEl.textContent = 'Testing...';
            resultEl.style.color = '#666';
            saveGitSettings();
            setTimeout(function() {
                var remote = document.getElementById('settings-git-remote').value.trim();
                if (!remote) {
                    resultEl.textContent = 'No remote URL configured.';
                    resultEl.style.color = '#e81123';
                    return;
                }
                resultEl.textContent = 'Settings saved. The agent can now use git push/pull with the configured remote.';
                resultEl.style.color = '#107c10';
            }, 1500);
        }
        function saveSettings() { if (!ws || ws.readyState !== WebSocket.OPEN) return; var updates = {}; var host = document.getElementById('settings-ollama-host').value.trim(); var model = document.getElementById('settings-ollama-model').value.trim(); var perm = document.getElementById('settings-perm-mode').value; var ctx = parseInt(document.getElementById('settings-max-context-tokens').value); var timeout = parseInt(document.getElementById('settings-llm-timeout').value); var idle = parseInt(document.getElementById('settings-idle-timeout').value); if (host) updates.ollama_host = host; if (model) updates.ollama_model = model; if (perm) updates.permission_mode = perm; if (ctx > 0) updates.max_context_tokens = ctx; if (timeout > 0) updates.llm_timeout_ms = timeout; if (idle > 0) updates.idle_timeout_minutes = idle; ws.send(JSON.stringify({type: 'set_config', updates: updates})); }
        document.getElementById('overlay-modal').addEventListener('click', function(e) { if (e.target === this) closeModal(); });
        window.addEventListener('storage', function(e) { if (e.key === 'openpixie_last_topic' && e.newValue && e.newValue !== currentTopicId) { } });
        window.addEventListener('beforeunload', function() { });

        // --- File Manager ---
        var filesCurrentPath = '/';
        var filesViewerPath = null;
        var filesViewerOriginal = '';

        function filesApiUrl(action, params) {
            var qs = 'action=' + encodeURIComponent(action);
            if (params) { qs += '&' + Object.keys(params).map(function(k) { return k + '=' + encodeURIComponent(params[k]); }).join('&'); }
            return '/api/v1/files?' + qs;
        }
        function filesFetch(url, opts) {
            return authFetch(url, opts);
        }
        function filesBrowse(path) {
            filesCurrentPath = path;
            document.getElementById('files-browser').style.display = '';
            document.getElementById('file-viewer').classList.remove('active');
            filesFetch(filesApiUrl('browse', {path: path})).then(function(r) { return r.json(); }).then(function(data) {
                if (data.is_file) { filesView(data.path); return; }
                filesRenderBreadcrumb(data.path || path);
                filesRenderList(data.entries || [], data.path || path);
            }).catch(function(err) { showToast('Failed to list files: ' + err.message, true); });
        }
        function filesRenderBreadcrumb(path) {
            var el = document.getElementById('files-breadcrumb');
            var parts = path.split('/').filter(function(p) { return p; });
            var html = '<span class="crumb" onclick="filesBrowse(\'/\')">root</span>';
            var accumulated = '';
            for (var i = 0; i < parts.length; i++) {
                accumulated += '/' + parts[i];
                html += '<span class="crumb-sep">/</span>';
                if (i === parts.length - 1) {
                    html += '<span class="crumb-current">' + escHtml(parts[i]) + '</span>';
                } else {
                    html += '<span class="crumb" onclick="filesBrowse(\'' + escHtml(accumulated) + '\')">' + escHtml(parts[i]) + '</span>';
                }
            }
            el.innerHTML = html;
        }
        function filesRenderList(entries, currentPath) {
            var tbody = document.getElementById('files-tbody');
            var emptyEl = document.getElementById('files-empty');
            tbody.innerHTML = '';
            if (entries.length === 0) { emptyEl.style.display = 'block'; return; }
            emptyEl.style.display = 'none';
            entries.forEach(function(e) {
                var tr = document.createElement('tr');
                var nameTd = document.createElement('td');
                var nameSpan = document.createElement('span');
                nameSpan.className = e.type === 'directory' ? 'dir-name' : 'file-name';
                nameSpan.textContent = e.name;
                nameSpan.onclick = (function(p, t) { return function() {
                    if (t === 'directory') filesBrowse(p); else filesView(p);
                }; })(e.path, e.type);
                nameTd.appendChild(nameSpan);
                tr.appendChild(nameTd);
                var sizeTd = document.createElement('td');
                sizeTd.textContent = e.type === 'directory' ? '--' : filesFormatSize(e.size || 0);
                tr.appendChild(sizeTd);
                var mtimeTd = document.createElement('td');
                mtimeTd.textContent = e.mtime || '';
                tr.appendChild(mtimeTd);
                var actsTd = document.createElement('td');
                actsTd.className = 'file-actions';
                if (e.type === 'file') {
                    var dlBtn = document.createElement('button'); dlBtn.textContent = '\u2193'; dlBtn.title = 'Download'; dlBtn.onclick = (function(p) { return function(e) { e.stopPropagation(); filesDownload(p); }; })(e.path); actsTd.appendChild(dlBtn);
                }
                var renBtn = document.createElement('button'); renBtn.textContent = '\u270E'; renBtn.title = 'Rename'; renBtn.onclick = (function(p) { return function(e) { e.stopPropagation(); filesShowRename(p); }; })(e.path); actsTd.appendChild(renBtn);
                var delBtn = document.createElement('button'); delBtn.className = 'btn-del'; delBtn.textContent = '\u2715'; delBtn.title = 'Delete'; delBtn.onclick = (function(p) { return function(e) { e.stopPropagation(); filesDelete(p); }; })(e.path); actsTd.appendChild(delBtn);
                tr.appendChild(actsTd);
                tbody.appendChild(tr);
            });
        }
        function filesFormatSize(bytes) {
            if (bytes < 1024) return bytes + ' B';
            if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
            if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + ' MB';
            return (bytes / 1073741824).toFixed(1) + ' GB';
        }
        function filesGoUp() {
            var parts = filesCurrentPath.split('/').filter(function(p) { return p; });
            parts.pop();
            filesBrowse('/' + parts.join('/'));
        }
        function filesRefresh() { filesBrowse(filesCurrentPath); }
        function filesView(path) {
            filesViewerPath = path;
            filesFetch(filesApiUrl('view', {path: path})).then(function(r) { return r.json(); }).then(function(data) {
                document.getElementById('files-browser').style.display = 'none';
                document.getElementById('file-viewer').classList.add('active');
                document.getElementById('file-viewer-path').textContent = data.path || path;
                if (data.too_large) {
                    document.getElementById('file-editor').style.display = 'none';
                    document.getElementById('file-binary-notice').style.display = 'block';
                    document.getElementById('file-binary-size').textContent = data.size;
                } else if (data.binary) {
                    document.getElementById('file-editor').style.display = 'none';
                    document.getElementById('file-binary-notice').style.display = 'block';
                    document.getElementById('file-binary-size').textContent = data.size;
                } else {
                    document.getElementById('file-editor').style.display = 'block';
                    document.getElementById('file-binary-notice').style.display = 'none';
                    document.getElementById('file-editor-textarea').value = data.content || '';
                    filesViewerOriginal = data.content || '';
                }
            }).catch(function(err) { showToast('Failed to view file: ' + err.message, true); });
        }
        function filesCloseViewer() {
            document.getElementById('file-viewer').classList.remove('active');
            document.getElementById('files-browser').style.display = '';
            filesViewerPath = null;
            filesBrowse(filesCurrentPath);
        }
        function filesSaveCurrent() {
            if (!filesViewerPath) return;
            var content = document.getElementById('file-editor-textarea').value;
            filesFetch('/api/v1/files', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({action: 'create', path: filesViewerPath, content: content})
            }).then(function(r) { return r.json(); }).then(function(data) {
                if (data.success) { showToast('File saved'); filesViewerOriginal = content; }
                else { showToast('Save failed: ' + (data.error || 'Unknown error'), true); }
            }).catch(function(err) { showToast('Save failed: ' + err.message, true); });
        }
        function filesDownload(path) {
            window.open(filesApiUrl('download', {path: path}).replace('/api/v1/files?', '/api/v1/files?action=download&'), '_blank');
        }
        function filesDownloadCurrent() {
            if (filesViewerPath) filesDownload(filesViewerPath);
        }
        function filesDelete(path) {
            if (!confirm('Delete ' + path + '? This cannot be undone.')) return;
            filesFetch('/api/v1/files', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({action: 'delete', path: path})
            }).then(function(r) { return r.json(); }).then(function(data) {
                if (data.success) { showToast('Deleted'); filesBrowse(filesCurrentPath); }
                else { showToast('Delete failed: ' + (data.error || 'Unknown error'), true); }
            }).catch(function(err) { showToast('Delete failed: ' + err.message, true); });
        }
        function filesShowRename(path) {
            var newName = prompt('New name:', path.split('/').pop());
            if (!newName) return;
            var newPath = path.substring(0, path.lastIndexOf('/') + 1) + newName;
            filesFetch('/api/v1/files', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({action: 'rename', old_path: path, new_path: newPath})
            }).then(function(r) { return r.json(); }).then(function(data) {
                if (data.success) { showToast('Renamed'); filesBrowse(filesCurrentPath); }
                else { showToast('Rename failed: ' + (data.error || 'Unknown error'), true); }
            }).catch(function(err) { showToast('Rename failed: ' + err.message, true); });
        }
        function showFileCreateModal() {
            var name = prompt('New file name:', '');
            if (!name) return;
            var path = filesCurrentPath === '/' ? '/' + name : filesCurrentPath + '/' + name;
            filesFetch('/api/v1/files', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({action: 'create', path: path, content: ''})
            }).then(function(r) { return r.json(); }).then(function(data) {
                if (data.success) { showToast('File created'); filesView(path); }
                else { showToast('Create failed: ' + (data.error || 'Unknown error'), true); }
            }).catch(function(err) { showToast('Create failed: ' + err.message, true); });
        }
        function showMkdirModal() {
            var name = prompt('New folder name:', '');
            if (!name) return;
            var path = filesCurrentPath === '/' ? '/' + name : filesCurrentPath + '/' + name;
            filesFetch('/api/v1/files', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({action: 'mkdir', path: path})
            }).then(function(r) { return r.json(); }).then(function(data) {
                if (data.success) { showToast('Folder created'); filesBrowse(filesCurrentPath); }
                else { showToast('Create failed: ' + (data.error || 'Unknown error'), true); }
            }).catch(function(err) { showToast('Create failed: ' + err.message, true); });
        }
        function showFileUploadModal() {
            var input = document.createElement('input'); input.type = 'file'; input.onchange = function() {
                var file = input.files[0]; if (!file) return;
                var reader = new FileReader();
                reader.onload = function(ev) {
                    var path = filesCurrentPath === '/' ? '/' + file.name : filesCurrentPath + '/' + file.name;
                    var isText = file.type && (file.type.startsWith('text/') || file.type === 'application/json' || file.type === 'application/javascript' || file.type.includes('erlang'));
                    var content = isText ? ev.target.result : btoa(ev.target.result);
                    var body = JSON.stringify({action: 'upload', path: path, content: content, encoding: isText ? 'utf8' : 'base64'});
                    filesFetch('/api/v1/files', {
                        method: 'POST',
                        headers: {'Content-Type': 'application/json'},
                        body: body
                    }).then(function(r) { return r.json(); }).then(function(data) {
                        if (data.success) { showToast('Uploaded ' + file.name + ' (' + filesFormatSize(data.size || file.size) + ')'); filesBrowse(filesCurrentPath); }
                        else { showToast('Upload failed: ' + (data.error || 'Unknown error'), true); }
                    }).catch(function(err) { showToast('Upload failed: ' + err.message, true); });
                };
                reader.readAsArrayBuffer(file);
            };
            input.click();
        }

        // --- Init ---
        loadKey();
        if (apiKey) {
            checkSession().then(function(ok) {
                if (ok) { apiKey = 'session'; sessionChecked = true; route(); connect(); }
                else { forceLogout(); }
            });
        } else {
            route();
        }
