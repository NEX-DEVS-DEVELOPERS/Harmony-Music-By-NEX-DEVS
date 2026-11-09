const domain = "https://music.youtube.com/";
const String baseUrl = '${domain}youtubei/v1/';
const fixedParms =
    '?prettyPrint=false&alt=json&key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
const userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

/// User agent the Android YouTube client uses; googlevideo stream URLs
/// obtained with that client should be fetched with the same one (else 403).
const streamUserAgent =
    'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip';
