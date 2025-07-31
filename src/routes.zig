const std = @import("std");
const httpz = @import("httpz");

pub fn handlePayment(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.status = 200;
}

pub fn handlePaymentsSummary(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.status = 200;
}

pub fn handleHealth(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.status = 200;
}
