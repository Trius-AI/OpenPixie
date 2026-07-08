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
let compactingEl = null;
const tabId = sessionStorage.getItem('openpixie_tab_id') || (sessionStorage.setItem('openpixie_tab_id', crypto.randomUUID()), sessionStorage.getItem('openpixie_tab_id'));
const topicStates = {};

