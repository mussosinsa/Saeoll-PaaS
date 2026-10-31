/* CI/CD console: tabs, confirmations, dialogs, form toggles, live logs. */
(function () {
  'use strict';

  // Confirm before submitting dangerous forms
  document.addEventListener('submit', function (e) {
    var msg = e.target.getAttribute('data-confirm');
    if (msg && !window.confirm(msg)) e.preventDefault();
  });

  document.addEventListener('click', function (e) {
    var btn = e.target.closest('[data-confirm-click]');
    if (btn && !window.confirm(btn.getAttribute('data-confirm-click'))) e.preventDefault();
  });

  // 품질 관리 dropdown (click for touch screens; hover/focus in CSS)
  document.querySelectorAll('.drop-btn').forEach(function (btn) {
    btn.addEventListener('click', function (e) {
      e.stopPropagation();
      btn.parentNode.classList.toggle('open');
    });
  });
  document.addEventListener('click', function () {
    document.querySelectorAll('.drop.open').forEach(function (d) { d.classList.remove('open'); });
  });

  // Dialogs
  document.querySelectorAll('[data-open]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var d = document.getElementById(btn.getAttribute('data-open'));
      if (d && d.showModal) d.showModal();
    });
  });
  document.querySelectorAll('dialog [data-close]').forEach(function (btn) {
    btn.addEventListener('click', function () { btn.closest('dialog').close(); });
  });

  // Tabs (hash based)
  var tabs = document.querySelector('[data-tabs]');
  if (tabs) {
    var show = function (id) {
      var found = false;
      tabs.querySelectorAll('a').forEach(function (a) {
        var on = a.getAttribute('href') === '#' + id;
        found = found || on;
        a.classList.toggle('on', on);
        var body = document.getElementById(a.getAttribute('href').slice(1));
        if (body) body.hidden = !on;
      });
      return found;
    };
    tabs.addEventListener('click', function (e) {
      var a = e.target.closest('a');
      if (!a) return;
      e.preventDefault();
      history.replaceState(null, '', a.getAttribute('href'));
      show(a.getAttribute('href').slice(1));
    });
    if (!(location.hash && show(location.hash.slice(1)))) show(tabs.querySelector('a').getAttribute('href').slice(1));
  }

  // Show fieldsets that depend on a radio value (data-for-source / data-for-mode)
  function toggle(name, attr) {
    var radios = document.querySelectorAll('input[name=' + name + ']');
    if (!radios.length) return;
    var update = function () {
      var checked = document.querySelector('input[name=' + name + ']:checked');
      document.querySelectorAll('[' + attr + ']').forEach(function (el) {
        el.hidden = !checked || el.getAttribute(attr) !== checked.value;
      });
    };
    radios.forEach(function (r) { r.addEventListener('change', update); });
    update();
  }
  toggle('source', 'data-for-source');
  toggle('mode', 'data-for-mode');

  // Auto reload while builds or syncs are running (not while a dialog is open)
  var auto = document.querySelector('[data-autoreload]');
  if (auto) {
    setTimeout(function reload() {
      if (document.querySelector('dialog[open]')) { setTimeout(reload, 5000); return; }
      location.reload();
    }, parseInt(auto.getAttribute('data-autoreload'), 10) * 1000);
  }

  function follow(pre) {
    var box = document.getElementById('log-follow');
    if (!box || box.checked) pre.scrollTop = pre.scrollHeight;
  }
  function state(text) {
    var el = document.getElementById('log-state');
    if (el) el.textContent = text;
  }
  function getJSON(url) {
    return fetch(url, { credentials: 'same-origin' }).then(function (r) {
      return r.json().then(function (body) {
        if (!r.ok) throw new Error(body.error || ('HTTP ' + r.status));
        return body;
      });
    });
  }

  window.CicdConsole = {
    // Jenkins (progressive text) or GitLab (job trace) build log
    buildLog: function (pre) {
      var base = pre.getAttribute('data-url');
      var start = 0, job = null, timer = null;
      var buttons = document.querySelectorAll('#gl-jobs .step');
      buttons.forEach(function (b) {
        b.addEventListener('click', function () {
          job = b.getAttribute('data-job');
          pre.textContent = '';
          clearTimeout(timer);
          poll();
        });
      });
      function mark() {
        buttons.forEach(function (b) { b.classList.toggle('on', String(job) === b.getAttribute('data-job')); });
      }
      function poll() {
        var url = base + '?start=' + start + (job ? '&job=' + job : '');
        getJSON(url).then(function (d) {
          if (d.append) { pre.textContent += d.text; start = d.next; } else { pre.textContent = d.text; job = d.job; mark(); }
          follow(pre);
          state(d.more ? '실행 중 - 3초마다 갱신' : '완료');
          if (d.more) timer = setTimeout(poll, 3000);
        }).catch(function (e) { state('로그 조회 실패: ' + e.message); timer = setTimeout(poll, 10000); });
      }
      poll();
    },

    // Script job output
    jobLog: function (pre) {
      var base = pre.getAttribute('data-url');
      var offset = 0;
      var labels = { success: '성공', failed: '실패', running: '실행 중', pending: '대기', manual: '수동 대기' };
      function poll() {
        getJSON(base + '?offset=' + offset).then(function (d) {
          if (d.lines.length) pre.textContent += d.lines.join('\n') + '\n';
          offset = d.offset;
          follow(pre);
          var badge = document.querySelector('#job-status .badge');
          if (badge) { badge.className = 'badge s-' + d.status; badge.textContent = labels[d.status] || d.status; }
          var manual = document.getElementById('job-manual');
          if (manual) manual.hidden = d.status !== 'manual';
          if (d.status === 'running' || d.status === 'pending') {
            state('실행 중 - 2초마다 갱신');
            setTimeout(poll, 2000);
          } else {
            state('종료 코드 ' + d.rc);
          }
        }).catch(function (e) { state('조회 실패: ' + e.message); setTimeout(poll, 5000); });
      }
      poll();
    }
  };
})();
