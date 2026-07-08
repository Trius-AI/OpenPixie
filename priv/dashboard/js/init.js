// --- Init ---
loadKey();
document.getElementById('topic-title').addEventListener('dblclick', startRenameTopic);
if (apiKey) {
    checkSession().then(function(ok) {
        if (ok) { apiKey = 'session'; sessionChecked = true; route(); connect(); }
        else { forceLogout(); }
    });
} else {
    route();
}
