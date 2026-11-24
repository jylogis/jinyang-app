// 진양 푸시 알림 서버 (Supabase Edge Function: push)
// GET            → 앱이 구독할 때 쓰는 공개키 반환 (처음 한 번 자동 생성해서 DB에 보관)
// POST {notice_id} → 공지 업체의 기사들 폰으로 알림 발송 (관리 권한 있는 사람만)
import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

const URL_ = Deno.env.get('SUPABASE_URL')!;
function secretKey(): string {
  // 새 키 체계(sb_secret_…)를 먼저, 없으면 예전 service_role 키
  try { const j = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}'); const v = j.default || Object.values(j)[0]; if (v) return String(v); } catch (_) { /* ignore */ }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
}
function publishableKey(): string {
  try { const j = JSON.parse(Deno.env.get('SUPABASE_PUBLISHABLE_KEYS') || '{}'); const v = j.default || Object.values(j)[0]; if (v) return String(v); } catch (_) { /* ignore */ }
  return Deno.env.get('SUPABASE_ANON_KEY') || '';
}
const SERVICE = secretKey();
const ANON_ENV = publishableKey();
const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } });

async function vapid() {
  const { data, error } = await admin.from('app_secrets').select('k,v').in('k', ['vapid_public', 'vapid_private']);
  if (error) throw new Error('secrets read: ' + error.message);
  const m: Record<string, string> = {};
  (data || []).forEach((r: { k: string; v: string }) => (m[r.k] = r.v));
  if (m.vapid_public && m.vapid_private) return { pub: m.vapid_public, priv: m.vapid_private };
  const k = webpush.generateVAPIDKeys();
  const up = await admin.from('app_secrets').upsert([{ k: 'vapid_public', v: k.publicKey }, { k: 'vapid_private', v: k.privateKey }]);
  if (up.error) throw new Error('secrets write: ' + up.error.message);
  return { pub: k.publicKey, priv: k.privateKey };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const keys = await vapid();
    if (req.method === 'GET') return json({ publicKey: keys.pub });

    // 보낸 사람 확인
    const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    if (!token) return json({ error: 'login required' }, 401);
    const userDb = createClient(URL_, ANON_ENV || req.headers.get('apikey') || '', { global: { headers: { Authorization: 'Bearer ' + token } }, auth: { persistSession: false } });
    // 앱이 DB를 쓸 때와 같은 방식(토큰 서명 확인)으로 사람 확인 → 다른 기기 로그아웃 등으로 세션이 끊겨도 앱이 쓰는 동안은 동작
    const who = await userDb.rpc('whoami');
    if (who.error || !who.data) return json({ error: 'login required', detail: who.error?.message || 'no user' }, 401);
    const u = { user: { id: String(who.data) } };

    const body = await req.json().catch(() => ({}));
    if (body.test) {
      // 내 폰으로 시험 알림
      const sent = await sendTo([u.user.id], { title: '진양로지스틱스', body: '알림 연결이 완료됐어요 ✅', url: './' }, keys);
      await log({ kind: 'test', title: '알림 연결 시험', sent_by: u.user.id, drivers: 1, ...sent });
      return json({ ok: true, ...sent });
    }
    if (body.kind === 'dispatch_request' || body.kind === 'dispatch_assigned') return json(await dispatchPush(body, u.user.id, userDb, keys));
    const { data: n } = await admin.from('notices').select('id,company_id,title,body,starts_at,ends_at').eq('id', body.notice_id).single();
    if (!n) return json({ error: 'notice not found' }, 404);
    const { data: can } = await userDb.rpc('can_manage', { cid: n.company_id });
    if (!can) return json({ error: 'forbidden' }, 403);
    const today = new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(0, 10); // 한국 날짜
    const base = { kind: 'notice', notice_id: n.id, company_id: n.company_id, title: n.title, sent_by: u.user.id };
    // 탭 관리의 '공지 알림' 설정 (Supabase tab_settings) 이 꺼져 있으면 보내지 않음
    const { data: ts } = await admin.from('tab_settings').select('notify').eq('tab', 'notice').maybeSingle();
    if (ts && ts.notify === false) { await log({ ...base, skipped: 'notify off' }); return json({ ok: true, skipped: 'notify off' }); }
    if ((n.starts_at && String(n.starts_at).slice(0, 10) > today) || (n.ends_at && String(n.ends_at).slice(0, 10) < today)) { await log({ ...base, skipped: 'out of posting period' }); return json({ ok: true, skipped: 'out of posting period' }); }

    const { data: ds } = await admin.from('drivers').select('id').eq('company_id', n.company_id).eq('status', '활성');
    const ids = (ds || []).map((d: { id: string }) => d.id);
    const text = String(n.body || '').replace(/\s+/g, ' ').slice(0, 120);
    const sent = await sendTo(ids, { title: '📢 새 공지 · ' + n.title, body: text || '새 공지가 올라왔어요. 눌러서 확인해 주세요.', url: './?source=noti&notice=' + n.id, tag: 'notice-' + n.id }, keys);
    await log({ ...base, drivers: ids.length, ...sent });
    return json({ ok: true, drivers: ids.length, ...sent });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});

// 배차 신청 알림: 기사가 신청 → 관리자·관리 권한자·배차 수정 권한 직급에게 / 배정 확정 → 신청한 기사에게
// deno-lint-ignore no-explicit-any
async function dispatchPush(body: any, uid: string, userDb: any, keys: { pub: string; priv: string }) {
  const { data: r } = await admin.from('dispatch_requests').select('*').eq('id', body.request_id).maybeSingle();
  if (!r) return { error: 'request not found' };
  const { data: d } = await admin.from('dispatches').select('id,route_name,work_date,company_id').eq('id', r.dispatch_id).maybeSingle();
  if (!d) return { error: 'dispatch not found' };
  const md = (() => { const p = String(d.work_date).split('-'); return (+p[1]) + '/' + (+p[2]); })();
  const url = './?source=noti&tab=dispatch&date=' + d.work_date;
  const { data: ts } = await admin.from('tab_settings').select('notify,perms').eq('tab', 'dispatch').maybeSingle();
  const base = { kind: body.kind, company_id: r.company_id, title: md + ' ' + d.route_name + ' · ' + r.driver_name, sent_by: uid };
  if (ts && ts.notify === false) { await log({ ...base, skipped: 'notify off' }); return { ok: true, skipped: 'notify off' }; }

  if (body.kind === 'dispatch_request') {
    if (r.driver_id !== uid) return { error: 'forbidden' };
    if (r.status !== '대기') return { ok: true, skipped: 'not pending' };
    const set = new Set<string>();
    const { data: ad } = await admin.from('admins').select('user_id'); (ad || []).forEach((x: { user_id: string }) => set.add(x.user_id));
    const { data: mg } = await admin.from('managers').select('driver_id,scope,company_ids');
    (mg || []).forEach((m: { driver_id: string; scope: string; company_ids: string[] | null }) => { if (m.scope === 'all' || (m.company_ids || []).includes(r.company_id)) set.add(m.driver_id); });
    const perms = (ts && ts.perms) || {};
    const editRanks = Object.keys(perms).filter((k) => perms[k] && perms[k].edit === true);
    if (editRanks.length) {
      const { data: ed } = await admin.from('drivers').select('id').eq('company_id', r.company_id).eq('status', '활성').in('rank', editRanks);
      (ed || []).forEach((x: { id: string }) => set.add(x.id));
    }
    set.delete(uid);
    const ids = [...set];
    const sent = await sendTo(ids, { title: '🙋 배차 신청 · ' + d.route_name, body: r.driver_name + ' ' + r.driver_rank + '님이 ' + md + ' ' + d.route_name + ' 배차를 신청했어요. 눌러서 배정해 주세요.', url, tag: 'dreq-' + r.id }, keys);
    await log({ ...base, drivers: ids.length, ...sent });
    return { ok: true, people: ids.length, ...sent };
  }
  // dispatch_assigned
  const { data: can } = await userDb.rpc('can_assign_dispatch', { cid: r.company_id });
  if (!can) return { error: 'forbidden' };
  if (r.status !== '배정') return { ok: true, skipped: 'not assigned' };
  const sent = await sendTo([r.driver_id], { title: '✅ 배차 확정 · ' + d.route_name, body: md + ' ' + d.route_name + ' 배차가 ' + r.driver_name + '님으로 확정됐어요.', url, tag: 'dok-' + r.id }, keys);
  await log({ ...base, drivers: 1, ...sent });
  return { ok: true, people: 1, ...sent };
}

// 발송 기록 저장 (실패해도 알림 자체는 막지 않음)
async function log(row: Record<string, unknown>) {
  const { error } = await admin.from('push_logs').insert(row);
  if (error) console.log('push log error', error.message);
}

async function sendTo(userIds: string[], payload: Record<string, string>, keys: { pub: string; priv: string }) {
  if (!userIds.length) return { devices: 0, sent: 0, removed: 0 };
  webpush.setVapidDetails('mailto:admin@jinyang.app', keys.pub, keys.priv);
  const { data: subs } = await admin.from('push_subs').select('endpoint,p256dh,auth').in('user_id', userIds);
  let sent = 0, removed = 0;
  const errors: { code?: number; body?: string; host?: string }[] = [];
  await Promise.all((subs || []).map(async (s: { endpoint: string; p256dh: string; auth: string }) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify(payload), { TTL: 60 * 60 * 24, urgency: 'high' });
      sent++;
    } catch (e) {
      const er = e as { statusCode?: number; body?: string; message?: string };
      const code = er.statusCode;
      errors.push({ code, body: String(er.body || er.message || '').slice(0, 200), host: new URL(s.endpoint).host });
      if (code === 404 || code === 410) { await admin.from('push_subs').delete().eq('endpoint', s.endpoint); removed++; }
    }
  }));
  if (errors.length) console.log('push errors', JSON.stringify(errors));
  return { devices: (subs || []).length, sent, removed, errors };
}
