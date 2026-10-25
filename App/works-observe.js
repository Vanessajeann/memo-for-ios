(function () {
  'use strict';
  if (!/^(?:www\.)?douyin\.com$/.test(location.hostname) || location.protocol !== 'https:') return;
  if (window.__memoWorksHook) return;
  window.__memoWorksHook = true;
  window.__memoWorksPages = [];
  var seen = Object.create(null);
  function target(raw) {
    try {
      var u = new URL(raw, location.href);
      if (u.protocol !== 'https:' || u.origin !== location.origin ||
          !/^\/aweme\/v1\/web\/aweme\/post\/?$/.test(u.pathname)) return null;
      return u;
    } catch (_) { return null; }
  }
  function save(raw, text) {
    var u = target(raw);
    if (!u || typeof text !== 'string' || text.length > 8000000) return;
    var body;
    try { body = JSON.parse(text); } catch (_) { return; }
    if (!body || typeof body !== 'object' ||
        (body.status_code !== undefined && Number(body.status_code) !== 0)) return;
    var list = body.aweme_list || (body.data && body.data.aweme_list);
    if (!Array.isArray(list)) return;
    var key = u.searchParams.get('sec_user_id') + ':' + (u.searchParams.get('max_cursor') || '0');
    if (seen[key]) return;
    seen[key] = true;
    window.__memoWorksPages.push({url: u.href, body: text});
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.memoPosts) window.webkit.messageHandlers.memoPosts.postMessage({url: u.href, body: text});
    if (window.__memoWorksPages.length > 4) window.__memoWorksPages.shift();
  }
  if (typeof window.fetch === 'function') {
    var fetch = window.fetch;
    window.fetch = function () {
      var raw = arguments[0] && arguments[0].url || arguments[0];
      var result = fetch.apply(this, arguments);
      result.then(function (response) {
        if (target(raw)) response.clone().text().then(function (text) {
          save(response.url || raw, text);
        }).catch(function () {});
      }).catch(function () {});
      return result;
    };
  }
  if (typeof XMLHttpRequest !== 'undefined') {
    var open = XMLHttpRequest.prototype.open;
    var send = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function () {
      this.__memoWorksUrl = arguments[1];
      return open.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      var xhr = this;
      if (target(xhr.__memoWorksUrl)) {
        xhr.addEventListener('load', function () {
          try {
            var text = xhr.responseType === 'json' ? JSON.stringify(xhr.response) : xhr.responseText;
            save(xhr.responseURL || xhr.__memoWorksUrl, text);
          } catch (_) {}
        }, {once: true});
      }
      return send.apply(this, arguments);
    };
  }
})();
