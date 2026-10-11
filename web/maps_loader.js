(() => {
  let loading;
  function loadScript(src) {
    return new Promise((resolve, reject) => {
      const script = document.createElement('script');
      const timeout = setTimeout(() => {
        script.remove();
        reject(new Error('Map library timed out'));
      }, 20000);
      script.src = src;
      script.async = true;
      script.onload = () => { clearTimeout(timeout); resolve(); };
      script.onerror = () => {
        clearTimeout(timeout);
        script.remove();
        reject(new Error('Map library could not load'));
      };
      document.head.appendChild(script);
    });
  }
  window.motorcycleLoadGoogleMaps = (key) => {
    if (!key) return Promise.reject(new Error('Map configuration missing'));
    if (loading) return loading;
    loading = (async () => {
      if (!window.markerClusterer) {
        await loadScript('https://cdn.jsdelivr.net/npm/@googlemaps/markerclusterer@2.5.3/dist/index.umd.min.js');
      }
      if (window.google?.maps?.Map) return;
      await new Promise((resolve, reject) => {
        const script = document.createElement('script');
        const finish = (error) => {
          clearTimeout(timeout);
          delete window.motorcycleMapsReady;
          if (error) { script.remove(); reject(error); } else { resolve(); }
        };
        const timeout = setTimeout(() => finish(new Error('Map load timed out')), 20000);
        window.motorcycleMapsReady = () => finish();
        window.gm_authFailure = () => finish(new Error('Map configuration rejected'));
        const params = new URLSearchParams({ key, loading: 'async', callback: 'motorcycleMapsReady', libraries: 'marker', language: 'zh-TW', region: 'TW', v: 'quarterly' });
        script.src = `https://maps.googleapis.com/maps/api/js?${params}`;
        script.async = true;
        script.onerror = () => finish(new Error('Map could not load'));
        document.head.appendChild(script);
      });
    })().catch(error => { loading = undefined; throw error; });
    return loading;
  };
})();
