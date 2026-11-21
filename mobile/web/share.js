// Deljenje i čuvanje ruke (istorija ruku).
window.trilingShare = {
  // "shared" (otvoren meni za deljenje), "copied" (kopirano), "cancel" ili "failed"
  share: async function (title, text) {
    try {
      if (navigator.share) {
        await navigator.share({ title: title, text: text });
        return 'shared';
      }
    } catch (e) {
      if (e && e.name === 'AbortError') return 'cancel';
    }
    try {
      await navigator.clipboard.writeText(text);
      return 'copied';
    } catch (e) {
      return 'failed';
    }
  },
  download: function (name, text) {
    try {
      const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = name;
      document.body.appendChild(a);
      a.click();
      setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
      return 'ok';
    } catch (e) {
      return 'failed';
    }
  },
};
