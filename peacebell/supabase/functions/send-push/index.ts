// 厝邊平安鈴 v2 ─ 推播發送（Supabase Edge Function：send-push）
// 由資料庫排程呼叫：取出待送通知 → 用 Web Push 推到志工手機
// 需要的 Secrets：CRON_SECRET、VAPID_PUBLIC_KEY、VAPID_PRIVATE_KEY、VAPID_SUBJECT
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") ?? "mailto:peacebell@example.com",
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);

type Item = {
  title: string; body: string; url: string; tag: string;
  endpoint: string; p256dh: string; auth: string;
};

Deno.serve(async (req) => {
  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) {
    return new Response("forbidden", { status: 403 });
  }
  const { data, error } = await sb.rpc("claim_notifications");
  if (error) return new Response(JSON.stringify(error), { status: 500 });

  const list = (data ?? []) as Item[];
  let sent = 0, dropped = 0, failed = 0;
  await Promise.all(list.map(async (n) => {
    try {
      await webpush.sendNotification(
        { endpoint: n.endpoint, keys: { p256dh: n.p256dh, auth: n.auth } },
        JSON.stringify({ title: n.title, body: n.body, url: n.url, tag: n.tag }),
        { TTL: 3600, urgency: "high" },
      );
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) {            // 手機已取消訂閱
        await sb.from("push_subscriptions").delete().eq("endpoint", n.endpoint);
        dropped++;
      } else {
        failed++;
        console.error("push failed", code, (e as { body?: string }).body);
      }
    }
  }));
  return new Response(JSON.stringify({ total: list.length, sent, dropped, failed }), {
    headers: { "Content-Type": "application/json" },
  });
});
