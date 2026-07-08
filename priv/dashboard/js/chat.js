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
            var item = document.createElement('a');
            item.href = '/chat/' + t.id;
            item.className = 'topic-item' + (t.id === currentTopicId ? ' active' : '') + (t.status === 'resolved' ? ' resolved' : '');
            item.setAttribute('data-topic-id', t.id);
            var dot = document.createElement('span');
            var ts = getTopicState(t.id); var hasUnread = ts && ts.unread > 0;
            dot.className = 'status-dot ' + (hasUnread ? 'unread' : (t.active ? 'active' : (t.status || 'idle')));
            item.appendChild(dot);
            var title = document.createElement('span'); title.className = 'topic-title-text'; title.textContent = t.title || t.id.substring(0, 8); item.appendChild(title);
            if (t.status === 'resolved') { var check = document.createElement('span'); check.className = 'resolved-check'; check.textContent = ' \u2713'; item.appendChild(check); }
            var del = document.createElement('span'); del.className = 'delete-btn'; del.textContent = '\u2715';
            del.onclick = (function(tid) { return function(e) { e.preventDefault(); e.stopPropagation(); deleteTopicById(tid); }; })(t.id);
            item.appendChild(del);
            item.onclick = (function(tid) { return function(e) { if (e.ctrlKey || e.metaKey || e.shiftKey) return; e.preventDefault(); switchTopic(tid); }; })(t.id);
            topicListEl.appendChild(item);
        });
        var collapsed = false;
        header.onclick = function() { collapsed = !collapsed; topicListEl.className = 'topic-list' + (collapsed ? ' collapsed' : ''); header.querySelector('.arrow').className = 'arrow' + (collapsed ? ' collapsed' : ''); };
        chDiv.appendChild(header); chDiv.appendChild(topicListEl); container.appendChild(chDiv);
    });
}

// --- Topic management ---
function startRenameTopic() {
    if (!currentTopicId || !ws || ws.readyState !== WebSocket.OPEN) return;
    var el = document.getElementById('topic-title');
    if (el.querySelector('input')) return;
    var currentTitle = el.textContent;
    var input = document.createElement('input');
    input.type = 'text'; input.value = currentTitle; input.className = 'topic-rename-input';
    el.textContent = ''; el.appendChild(input); input.focus(); input.select();
    var done = function() {
        var newTitle = input.value.trim();
        if (input.parentNode) { el.textContent = newTitle || currentTitle; }
        if (newTitle && newTitle !== currentTitle) { ws.send(JSON.stringify({type: 'rename_topic', topic_id: currentTopicId, title: newTitle})); }
    };
    input.addEventListener('blur', done);
    input.addEventListener('keydown', function(e) { if (e.key === 'Enter') { e.preventDefault(); input.blur(); } if (e.key === 'Escape') { input.value = currentTitle; input.blur(); } });
}
function switchTopic(topicId) { if (!ws || ws.readyState !== WebSocket.OPEN) return; if (topicId === currentTopicId) return; history.pushState(null, '', '/chat/' + topicId); ws.send(JSON.stringify({type: 'switch_topic', topic_id: topicId})); }
function clearChat() { document.getElementById('chat-area').innerHTML = ''; lastThinkingEl = null; streamingEl = null; streamingRawText = ''; lastToolStepEl = null; lastGuardianBadgeEl = null; compactingEl = null; messageIndex = 0; }

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
    else if (role === 'system' && fullMsg && fullMsg.error_detail) {
        var errorType = fullMsg.error_type || '';
        var isOllamaError = typeof errorType === 'string' && (errorType.indexOf('{status,') >= 0 || errorType === 'econnrefused' || errorType === 'timeout' || errorType === 'circuit_open' || errorType === 'nxdomain' || errorType.indexOf('stream_timeout') >= 0);
        div.className = isOllamaError ? 'msg system ollama-error' : 'msg system';
        contentEl.className = 'msg-content md';
        contentEl.innerHTML = (isOllamaError ? '<span class="error-icon">⚠</span> ' : '') + renderMarkdown((content || '').toString());
        if (fullMsg.error_detail) {
            var detailEl = document.createElement('details');
            var summaryEl = document.createElement('summary');
            summaryEl.textContent = 'Error details';
            detailEl.appendChild(summaryEl);
            var detailPre = document.createElement('pre');
            detailPre.className = 'error-detail-pre';
            detailPre.textContent = typeof fullMsg.error_detail === 'object' ? JSON.stringify(fullMsg.error_detail, null, 2) : String(fullMsg.error_detail);
            detailEl.appendChild(detailPre);
            contentEl.appendChild(detailEl);
        }
        div.appendChild(contentEl);
    }
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
function compactTopic() { if (!ws || ws.readyState !== WebSocket.OPEN) return; if (!currentTopicId) return; compactingEl = addMessage('system', 'Compacting conversation...'); ws.send(JSON.stringify({type: 'compact'})); }
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

