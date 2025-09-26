
const kHttpMethodGet = 'GET';
const kHttpMethodHead = 'HEAD';

const kHttpHeaderAge = 'age';
const kHttpHeaderCacheControl = 'cache-control';
const kHttpHeaderContentLength = 'content-length';
const kHttpHeaderContentType = 'content-type';
const kHttpHeaderDate = 'date';
const kHttpHeaderETag = 'etag';
const kHttpHeaderExpires = 'expires';
const kHttpHeaderIfModifiedSinceHeader = 'if-modified-since';
const kHttpHeaderIfNoneMatchHeader = 'if-none-match';
const kHttpHeaderLastModifiedHeader = 'last-modified';
const kHttpHeaderVary = 'vary';

const kHttpStatusOk = 200;
const kHttpStatusNotModified = 304;
const kHttpStatusNotFound = 404;

const kHttpVaryWildcard = '*';

typedef Headers = Map<String, String>;
