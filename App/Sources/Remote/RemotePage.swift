//
// Vespertine Remote: the page the phone opens. Plain HTML, CSS and JavaScript, no libraries.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

nonisolated enum RemotePage {
    /// Song titles and names are put on the page as text (never as HTML), so a file's tags can't run anything.
    static let html = #"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="Vespertine">
    <meta name="theme-color" content="#0d0d0f">
    <title>Vespertine Remote</title>
    <style>
    :root { --bg:#0d0d0f; --surface:#16161a; --raised:#1c1c21; --text:#ece6da; --text2:#a29b8f; --accent:#8fb3d9; --line:rgba(236,230,218,.1); }
    * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
    html, body { margin:0; background:var(--bg); color:var(--text); font:16px -apple-system, system-ui, sans-serif; }
    body { padding:env(safe-area-inset-top) 20px calc(env(safe-area-inset-bottom) + 24px); max-width:520px; margin:0 auto; }
    .hidden { display:none !important; }
    #banner { background:var(--raised); color:var(--text2); font-size:14px; text-align:center; padding:8px; margin:12px 0 0; border-radius:10px; }
    #login { padding-top:20vh; text-align:center; }
    #login h1 { font-size:22px; font-weight:600; margin:0 0 6px; }
    #login p { color:var(--text2); margin:0 0 24px; }
    #pin { width:200px; font-size:28px; letter-spacing:.3em; text-align:center; padding:12px; border-radius:12px; border:1px solid var(--line); background:var(--surface); color:var(--text); }
    #go { display:block; margin:18px auto 0; width:200px; padding:14px; font-size:17px; border:0; border-radius:12px; background:var(--accent); color:#0d0d0f; font-weight:600; }
    #loginError { color:var(--text2); height:22px; margin-top:14px; font-size:14px; }
    #art { width:100%; aspect-ratio:1; border-radius:14px; background:var(--surface); margin-top:18px; object-fit:cover; display:block; }
    #meta { margin-top:18px; }
    #title { font-size:22px; font-weight:600; line-height:1.2; overflow-wrap:anywhere; }
    #artist, #album { color:var(--text2); margin-top:4px; overflow-wrap:anywhere; }
    #format { margin-top:10px; font-size:12px; letter-spacing:.06em; color:var(--text2); }
    #format b { color:var(--accent); font-weight:600; margin-right:8px; }
    #bar { margin-top:20px; }
    input[type=range] { width:100%; margin:0; accent-color:var(--accent); height:28px; }
    .times { display:flex; justify-content:space-between; font-size:13px; color:var(--text2); font-variant-numeric:tabular-nums; }
    #controls { display:flex; justify-content:space-between; align-items:center; margin:14px 0 6px; }
    #controls button { background:none; border:0; color:var(--text); padding:12px; border-radius:50%; width:56px; height:56px; display:flex; align-items:center; justify-content:center; }
    #controls button:active { background:var(--raised); }
    #controls button.small { color:var(--text2); width:48px; height:48px; }
    #controls button.on { color:var(--accent); }
    #toggle { background:var(--text) !important; color:#0d0d0f !important; width:72px !important; height:72px !important; }
    svg { width:28px; height:28px; fill:currentColor; }
    #toggle svg { width:34px; height:34px; }
    h2 { font-size:13px; letter-spacing:.08em; text-transform:uppercase; color:var(--text2); font-weight:600; margin:26px 0 8px; }
    .row { display:block; width:100%; text-align:left; background:none; border:0; border-top:1px solid var(--line); color:var(--text); padding:11px 2px; }
    .row .t { font-size:16px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .row .a { font-size:13px; color:var(--text2); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; margin-top:2px; }
    .row:active { background:var(--raised); }
    .row.q .t::before { content:"\2022 "; color:var(--accent); }
    #empty { color:var(--text2); padding:14px 0; font-size:14px; }
    </style>
    </head>
    <body>
    <div id="banner" class="hidden"></div>

    <div id="login" class="hidden">
      <h1>Vespertine Remote</h1>
      <p>Enter the PIN shown in Vespertine's Settings.</p>
      <input id="pin" type="password" inputmode="numeric" pattern="[0-9]*" autocomplete="off" maxlength="12" aria-label="PIN">
      <button id="go">Connect</button>
      <div id="loginError"></div>
    </div>

    <div id="player" class="hidden">
      <img id="art" alt="" class="hidden">
      <div id="meta">
        <div id="title">Nothing playing</div>
        <div id="artist"></div>
        <div id="album"></div>
        <div id="format"></div>
      </div>
      <div id="bar">
        <input id="seek" type="range" min="0" max="0" step="0.1" value="0" aria-label="Position">
        <div class="times"><span id="pos">0:00</span><span id="dur">0:00</span></div>
      </div>
      <div id="controls">
        <button id="shuffle" class="small" aria-label="Shuffle"><svg viewBox="0 0 24 24"><path d="M17 3l4 4-4 4V8h-2.6l-3.3 4.1L8.6 15H4v-2h3.6l2.3-2.9L7.6 7.2H4v-2h4.4l2.7 3.4L13.4 5H17V3zm0 10l4 4-4 4v-3h-3.6l-2-2.5 1.3-1.6 1.3 1.6H17v-2z"/></svg></button>
        <button id="prev" aria-label="Previous"><svg viewBox="0 0 24 24"><path d="M6 5h2v14H6zM20 5v14L9.5 12z"/></svg></button>
        <button id="toggle" aria-label="Play or pause"></button>
        <button id="next" aria-label="Next"><svg viewBox="0 0 24 24"><path d="M16 5h2v14h-2zM4 5l10.5 7L4 19z"/></svg></button>
        <button id="repeat" class="small" aria-label="Repeat"></button>
      </div>
      <h2>Up next</h2>
      <div id="queue"></div>
      <div id="empty" class="hidden">Nothing queued.</div>
    </div>

    <script>
    (function () {
      var PLAY = '<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>';
      var PAUSE = '<svg viewBox="0 0 24 24"><path d="M6 5h4v14H6zM14 5h4v14h-4z"/></svg>';
      var REPEAT = '<svg viewBox="0 0 24 24"><path d="M7 7h10v3l4-4-4-4v3H5v6h2zM17 17H7v-3l-4 4 4 4v-3h12v-6h-2z"/></svg>';
      var REPEAT_ONE = '<svg viewBox="0 0 24 24"><path d="M7 7h10v3l4-4-4-4v3H5v6h2zM17 17H7v-3l-4 4 4 4v-3h12v-6h-2zm-4-2V9h-1l-2 1v1h1.5v4z"/></svg>';
      var $ = function (id) { return document.getElementById(id); };
      var pin = '';
      try { pin = localStorage.getItem('vespertinePin') || ''; } catch (e) {}
      var state = null, stateAt = 0, dragging = false, artKey = null, artURL = null, busy = false, lastOK = Date.now();

      function show(id, on) { $(id).classList.toggle('hidden', !on); }
      function banner(text) { $('banner').textContent = text || ''; show('banner', !!text); }
      function fmt(s) { s = Math.max(0, Math.floor(s || 0)); var m = Math.floor(s / 60), r = s % 60; return m + ':' + (r < 10 ? '0' : '') + r; }

      function call(method, path) {
        return fetch(path, { method: method, headers: { 'X-Pin': pin }, cache: 'no-store' }).then(function (r) {
          if (r.status === 401) { throw 'pin'; }
          if (r.status === 429) { throw 'locked'; }
          if (!r.ok) { throw 'error'; }
          return r;
        });
      }

      function applyState(s) {
        state = s; stateAt = Date.now(); lastOK = stateAt;
        show('login', false); show('player', true); banner('');
        $('title').textContent = s.title || 'Nothing playing';
        $('artist').textContent = s.artist || '';
        $('album').textContent = s.album || '';
        var f = $('format'); f.textContent = '';
        if (s.title) {
          if (s.bitPerfect) { var b = document.createElement('b'); b.textContent = 'BIT-PERFECT'; f.appendChild(b); }
          var parts = [];
          if (s.codec) { parts.push(String(s.codec).toUpperCase()); }
          if (s.sampleRate) { parts.push((s.sampleRate / 1000).toFixed(s.sampleRate % 1000 ? 1 : 0) + ' kHz'); }
          if (s.bitDepth) { parts.push(s.bitDepth + '-bit'); }
          f.appendChild(document.createTextNode(parts.join(' · ')));
        }
        $('toggle').innerHTML = s.state === 'playing' ? PAUSE : PLAY;
        $('shuffle').classList.toggle('on', !!s.shuffle);
        $('repeat').classList.toggle('on', s.repeat !== 'off');
        $('repeat').innerHTML = s.repeat === 'one' ? REPEAT_ONE : REPEAT;
        $('seek').max = s.duration || 0;
        $('dur').textContent = fmt(s.duration);
        if (!dragging) { $('seek').value = s.position; $('pos').textContent = fmt(s.position); }
        setArt(s);
        renderQueue(s.queue || []);
      }

      function setArt(s) {
        var key = s.art || '';
        if (key === artKey) { return; }
        artKey = key;
        if (!key) { show('art', false); return; }
        call('GET', '/api/art').then(function (r) { return r.blob(); }).then(function (blob) {
          if (artURL) { URL.revokeObjectURL(artURL); }
          artURL = URL.createObjectURL(blob);
          $('art').src = artURL; show('art', true);
        }).catch(function () { show('art', false); });
      }

      function renderQueue(items) {
        var box = $('queue');
        box.textContent = '';
        items.forEach(function (it) {
          var row = document.createElement('button');
          row.className = 'row' + (it.queued ? ' q' : '');
          var t = document.createElement('div'); t.className = 't'; t.textContent = it.title;
          var a = document.createElement('div'); a.className = 'a'; a.textContent = it.artist;
          row.appendChild(t); row.appendChild(a);
          row.onclick = function () { command('POST', '/api/jump?id=' + encodeURIComponent(it.id)); };
          box.appendChild(row);
        });
        show('empty', items.length === 0);
      }

      function failed(e) {
        if (e === 'pin') {
          try { localStorage.removeItem('vespertinePin'); } catch (x) {}
          pin = ''; show('player', false); show('login', true); banner('');
        } else if (e === 'locked') {
          banner('Too many wrong PINs. Try again in a minute.');
        } else if (Date.now() - lastOK > 4000) {
          banner("Can't reach Vespertine. Is the Mac awake and the remote switched on?");
        }
      }

      function poll() {
        if (busy || document.hidden || !pin) { return; }
        busy = true;
        call('GET', '/api/state').then(function (r) { return r.json(); }).then(applyState).catch(failed).then(function () { busy = false; });
      }

      function command(method, path) {
        call(method, path).then(function (r) { return r.json(); }).then(applyState).catch(failed);
      }

      $('toggle').onclick = function () { command('POST', '/api/toggle'); };
      $('next').onclick = function () { command('POST', '/api/next'); };
      $('prev').onclick = function () { command('POST', '/api/previous'); };
      $('shuffle').onclick = function () { command('POST', '/api/shuffle'); };
      $('repeat').onclick = function () { command('POST', '/api/repeat'); };
      var seek = $('seek');
      seek.addEventListener('input', function () { dragging = true; $('pos').textContent = fmt(seek.value); });
      seek.addEventListener('change', function () {
        var to = seek.value; dragging = false;
        command('POST', '/api/seek?to=' + encodeURIComponent(to));
      });

      function login() {
        var value = $('pin').value.trim();
        if (!value) { return; }
        pin = value; $('loginError').textContent = '';
        call('GET', '/api/state').then(function (r) { return r.json(); }).then(function (s) {
          try { localStorage.setItem('vespertinePin', pin); } catch (e) {}
          applyState(s);
        }).catch(function (e) {
          $('loginError').textContent = e === 'locked' ? 'Too many tries. Wait a minute.' : e === 'pin' ? 'That PIN is not right.' : "Can't reach Vespertine.";
          pin = '';
        });
      }
      $('go').onclick = login;
      $('pin').addEventListener('keydown', function (e) { if (e.key === 'Enter') { login(); } });

      // Between polls, keep the progress moving while a song plays.
      setInterval(function () {
        if (!state || dragging || state.state !== 'playing') { return; }
        var p = Math.min(state.duration || 0, state.position + (Date.now() - stateAt) / 1000);
        $('seek').value = p; $('pos').textContent = fmt(p);
      }, 250);
      setInterval(poll, 1000);
      document.addEventListener('visibilitychange', poll);

      if (pin) { poll(); } else { show('login', true); }
    })();
    </script>
    </body>
    </html>
    """#
}
