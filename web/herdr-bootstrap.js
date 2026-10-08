const e = new URL(window.__HERDR_ENTRY__ || "/builds/0.22.6-398-f0e58a2d2edff137/index.html", location);
  e.search = location.search;
  e.hash = location.hash;
  location.replace(e);
