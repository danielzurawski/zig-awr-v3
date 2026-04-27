const std = @import("std");

pub const KalmanFilter = struct {
    q: f32, // Process noise
    r: f32, // Measurement noise
    p_k_k1: f32 = 1.0,
    kg: f32 = 0.0,
    p_k1_k1: f32 = 1.0,
    x_k_k1: f32 = 0.0,
    kalman_adc_old: f32 = 0.0,

    pub fn init(q: f32, r: f32) KalmanFilter {
        return .{ .q = q, .r = r };
    }

    pub fn filter(self: *KalmanFilter, measurement: f32) f32 {
        // Prediction
        const x_k1_k1 = if (@abs(self.kalman_adc_old - measurement) >= 60)
            measurement * 0.382 + self.kalman_adc_old * 0.618
        else
            self.kalman_adc_old;

        self.x_k_k1 = x_k1_k1;
        self.p_k_k1 = self.p_k1_k1 + self.q;

        // Update
        self.kg = self.p_k_k1 / (self.p_k_k1 + self.r);
        const kalman_adc = self.x_k_k1 + self.kg * (measurement - self.kalman_adc_old);
        self.p_k1_k1 = (1.0 - self.kg) * self.p_k_k1;
        self.p_k_k1 = self.p_k1_k1;
        self.kalman_adc_old = kalman_adc;

        return kalman_adc;
    }

    pub fn reset(self: *KalmanFilter) void {
        self.p_k_k1 = 1.0;
        self.kg = 0.0;
        self.p_k1_k1 = 1.0;
        self.x_k_k1 = 0.0;
        self.kalman_adc_old = 0.0;
    }
};

test "KalmanFilter converges" {
    var kf = KalmanFilter.init(0.01, 0.1);
    // Feed constant value, should converge
    var last: f32 = 0;
    for (0..20) |_| {
        last = kf.filter(100.0);
    }
    try std.testing.expect(@abs(last - 100.0) < 5.0);
}