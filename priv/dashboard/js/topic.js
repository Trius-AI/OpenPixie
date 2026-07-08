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
            if (location.pathname !== '/chat/' + data.topic_id) history.replaceState(null, '', '/chat/' + data.topic_id);
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
            if (errTopic === currentTopicId || !errTopic) { removeThinking(); finalizeStreaming(); addMessage('system', data.message || data.error || 'Unknown error', null, {error_detail: data.raw_error, error_type: data.error}); }
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
        case 'topic_renamed':
           if (data.topic_id === currentTopicId) { document.getElementById('topic-title').textContent = data.title || 'Untitled'; }
           ws.send(JSON.stringify({type: 'list_topics'})); break;
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
        case 'compact_result':
            isSending = false; updateSendButton();
            if (compactingEl && compactingEl.parentNode) { compactingEl.parentNode.removeChild(compactingEl); compactingEl = null; }
            if (data.status === 'ok') {
                addMessage('system', 'Conversation compacted. ' + (data.original_count || '?') + ' messages summarized into context. Recent messages preserved.');
                ws.send(JSON.stringify({type: 'switch_topic', topic_id: currentTopicId}));
            } else {
                addMessage('system', data.message || 'Compact failed.');
            }
            break;
    }
}

