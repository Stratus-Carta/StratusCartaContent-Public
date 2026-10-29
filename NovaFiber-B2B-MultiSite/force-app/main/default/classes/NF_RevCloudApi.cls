/**
 * NF_RevCloudApi
 * Revenue Cloud Connect REST APIs called through the NF_RevenueCloud named credential
 * (OAuth client credentials → NF Revenue Cloud API external client app). Works the same
 * for agents and guest visitors, synchronously.
 *
 *   Product Discovery   POST /connect/cpq/products
 *   Product details     POST /connect/cpq/products/bulk
 *   Configurator        POST /connect/cpq/configurator/actions/configure   (Context Service session)
 *   Place Sales Trxn    POST /connect/rev/sales-transaction/actions/place
 *   Quote → Order       POST /actions/standard/createOrdersFromQuote
 *   Pricing data        GET  /connect/core-pricing/sync/syncData
 *
 * Every call is recorded in NF_Trace (kind RC_API) with request/response for the inspector.
 */
public inherited sharing class NF_RevCloudApi {

    public static final String API = '/services/data/v66.0';
    @TestVisible private static final String BASE = 'callout:NF_RevenueCloud';
    private static final Integer TIMEOUT_MS = 60000;

    /** Test double for the Connect APIs: returns the response body for a request (status 200). */
    public interface Responder {
        String respond(String method, String path, String requestBody);
    }
    @TestVisible private static Responder responder;

    public class RevCloudException extends Exception {}

    public static Map<String, Object> post(String path, Object body, String label) {
        return send('POST', path, body, label, null);
    }

    public static Map<String, Object> post(String path, Object body, String label, Map<String, String> headers) {
        return send('POST', path, body, label, headers);
    }

    public static Map<String, Object> get(String path, String label) {
        return send('GET', path, null, label, null);
    }

    public static Map<String, Object> patch(String path, Object body, String label, Map<String, String> headers) {
        return send('PATCH', path, body, label, headers);
    }

    public static Map<String, Object> del(String path, String label) {
        return send('DELETE', path, null, label, null);
    }

    /** SOQL as the integration user (objects site visitors cannot read, e.g. contracts and document templates). */
    public static List<Map<String, Object>> query(String soql, String label) {
        Map<String, Object> res = get('/query?q=' + EncodingUtil.urlEncode(soql, 'UTF-8'), label);
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        if (res.get('records') instanceof List<Object>) {
            for (Object o : (List<Object>) res.get('records')) rows.add((Map<String, Object>) o);
        }
        return rows;
    }

    /** GET of a binary resource (e.g. ContentVersion/{id}/VersionData), not parsed. */
    public static Blob getBlob(String path, String label) {
        NF_Trace.Entry t = NF_Trace.start('RC_API', 'GET ' + path, label);
        if (responder != null) {
            NF_Trace.end(t, 'OK', 'HTTP 200 (binary)');
            return Blob.valueOf(responder.respond('GET', path, null));
        }
        HttpRequest req = new HttpRequest();
        req.setEndpoint(BASE + API + path);
        req.setMethod('GET');
        req.setTimeout(TIMEOUT_MS);
        HttpResponse res = new Http().send(req);
        Boolean ok = res.getStatusCode() >= 200 && res.getStatusCode() < 300;
        NF_Trace.end(t, ok ? 'OK' : 'ERROR', 'HTTP ' + res.getStatusCode() + (ok ? ' · ' + res.getBodyAsBlob().size() + ' bytes' : '\n' + res.getBody()));
        if (!ok) throw new RevCloudException('Download ' + path + ' failed (HTTP ' + res.getStatusCode() + ')');
        return res.getBodyAsBlob();
    }

    /** POST that returns a JSON array (e.g. invocable actions). */
    public static List<Object> postList(String path, Object body, String label) {
        Object parsed = call('POST', path, body, label, null);
        return parsed instanceof List<Object> ? (List<Object>) parsed : new List<Object>{ parsed };
    }

    private static Map<String, Object> send(String method, String path, Object body, String label, Map<String, String> headers) {
        Object parsed = call(method, path, body, label, headers);
        if (parsed instanceof Map<String, Object>) return (Map<String, Object>) parsed;
        return new Map<String, Object>{ 'result' => parsed };
    }

    private static Object call(String method, String path, Object body, String label, Map<String, String> headers) {
        String url = API + path;
        NF_Trace.Entry t = NF_Trace.start('RC_API', method + ' ' + path, label);
        if (body != null) NF_Trace.request(t, body);

        String requestBody = body == null ? null : (body instanceof String ? (String) body : JSON.serialize(body, true));
        String responseBody;
        Integer status;
        if (responder != null) {
            status = 200;
            responseBody = responder.respond(method, path, requestBody);
        } else {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(BASE + url);
            req.setMethod(method);
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            req.setTimeout(TIMEOUT_MS);
            if (headers != null) {
                for (String h : headers.keySet()) req.setHeader(h, headers.get(h));
            }
            if (requestBody != null) req.setBody(requestBody);
            HttpResponse res;
            try {
                res = new Http().send(req);
            } catch (CalloutException e) {
                NF_Trace.end(t, 'ERROR', e.getMessage());
                throw new RevCloudException('Revenue Cloud is not reachable: ' + e.getMessage());
            }
            status = res.getStatusCode();
            responseBody = res.getBody();
        }

        Object parsed;
        try {
            parsed = String.isBlank(responseBody) ? new Map<String, Object>() : JSON.deserializeUntyped(responseBody);
        } catch (JSONException e) {
            parsed = new Map<String, Object>{ 'raw' => responseBody };
        }
        Boolean ok = status >= 200 && status < 300;
        NF_Trace.end(t, ok ? 'OK' : 'ERROR', 'HTTP ' + status + '\n' + responseBody);
        if (!ok) {
            throw new RevCloudException('Revenue Cloud API ' + path + ' failed (HTTP ' + status + '): ' + firstError(parsed));
        }
        return parsed;
    }

    /** Best-effort extraction of the first error message from a Connect API error payload. */
    public static String firstError(Object parsed) {
        if (parsed instanceof List<Object>) {
            List<Object> l = (List<Object>) parsed;
            if (!l.isEmpty() && l[0] instanceof Map<String, Object>) {
                Map<String, Object> m = (Map<String, Object>) l[0];
                if (m.get('message') != null) return String.valueOf(m.get('message'));
                if (m.get('errors') != null) return firstError(m.get('errors'));
            }
        } else if (parsed instanceof Map<String, Object>) {
            Map<String, Object> m = (Map<String, Object>) parsed;
            for (String k : new List<String>{ 'message', 'errorMessage' }) {
                if (m.get(k) != null) return String.valueOf(m.get(k));
            }
            for (String k : new List<String>{ 'errors', 'errorResponse' }) {
                if (m.get(k) != null) return firstError(m.get(k));
            }
        }
        return String.valueOf(parsed).left(300);
    }
}
