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

