{{flutter_js}}
{{flutter_build_config}}

// Bez Flutter-ovog service worker-a: aplikacija koristi svoj (push-sw.js) za obaveštenja,
// a dva service worker-a na istoj adresi bi smetala jedan drugom.
_flutter.loader.load();
