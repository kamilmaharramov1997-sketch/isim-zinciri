#!/bin/bash
# İsim Zinciri: bildirim sunucusunu (Cloud Functions) kurar. Google Cloud Shell'de çalıştırılır.
set -e
PROJECT=isim-zinciri-aeb8d
echo ""
echo "=== İsim Zinciri bildirim kurulumu başlıyor ==="
gcloud config set project $PROJECT >/dev/null 2>&1 || true
LOC=$(gcloud firestore databases describe --database='(default)' --format='value(locationId)' 2>/dev/null || echo "eur3")
case "$LOC" in
  eur3) REGION=europe-west1 ;;
  nam5) REGION=us-central1 ;;
  nam7) REGION=us-central1 ;;
  "") REGION=europe-west1 ;;
  *) REGION=$LOC ;;
esac
echo "Veritabanı konumu: $LOC  ->  sunucu bölgesi: $REGION"
DIR=~/iz-bildirim
rm -rf $DIR && mkdir -p $DIR/functions && cd $DIR
cat > firebase.json <<'EOF'
{ "functions": { "source": "functions", "runtime": "nodejs20" } }
EOF
cat > .firebaserc <<EOF
{ "projects": { "default": "$PROJECT" } }
EOF
cat > functions/package.json <<'EOF'
{ "name": "iz-bildirim", "main": "index.js", "engines": { "node": "20" },
  "dependencies": { "firebase-admin": "^12.7.0", "firebase-functions": "^6.1.0" } }
EOF
cat > functions/index.js <<'EOF'
const { onDocumentCreated, onDocumentUpdated } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { setGlobalOptions } = require('firebase-functions/v2');
const admin = require('firebase-admin');
admin.initializeApp();
setGlobalOptions({ region: '__REGION__', maxInstances: 5 });
const db = admin.firestore();
const TX = {
  tr: { invT: n => `📩 @${n} seni oyuna çağırıyor`, invB: c => `Oda ${c} · Katılmak için dokun`, join: 'Katıl', no: 'Yok say',
        frT: n => `👥 @${n} arkadaşlık isteği gönderdi`, frB: 'Kabul etmek için dokun', open: 'Aç',
        fbT: n => `✉️ Yeni geri bildirim: @${n}`, fbB: 'Yönetici panelinde görmek için dokun', rpT: '💬 Mesajına cevap geldi' },
  az: { invT: n => `📩 @${n} səni oyuna çağırır`, invB: c => `Otaq ${c} · Qoşulmaq üçün toxun`, join: 'Qoşul', no: 'Keç',
        frT: n => `👥 @${n} dostluq istəyi göndərdi`, frB: 'Qəbul etmək üçün toxun', open: 'Aç',
        fbT: n => `✉️ Yeni rəy: @${n}`, fbB: 'Admin panelində görmək üçün toxun', rpT: '💬 Mesajına cavab gəldi' } };
async function sendTo(uid, build){
  const col = db.collection('users').doc(uid).collection('tokens');
  const snap = await col.get();
  for (const d of snap.docs){
    const L = TX[(d.data().lang === 'az') ? 'az' : 'tr'];
    try {
      await admin.messaging().send({ token: d.id, data: build(L), webpush: { headers: { Urgency: 'high', TTL: '7200' } } });
    } catch (e) {
      const c = e && e.code || '';
      if (c.includes('registration-token-not-registered') || c.includes('invalid-registration-token') || c.includes('invalid-argument')) await col.doc(d.id).delete();
      else console.warn('send', uid, c);
    }
  }
}
exports.notifyInvite = onDocumentCreated('invites/{id}', e => {
  const d = e.data && e.data.data(); if (!d || !d.to) return;
  return sendTo(d.to, L => ({ type: 'invite', title: L.invT(d.fromName || ''), body: L.invB(d.room), a1: L.join, a2: L.no, url: './?oda=' + d.room, tag: 'inv-' + d.room }));
});
exports.notifyFriend = onDocumentCreated('friendReqs/{id}', e => {
  const d = e.data && e.data.data(); if (!d || !d.to) return;
  return sendTo(d.to, L => ({ type: 'friend', title: L.frT(d.fromName || ''), body: L.frB, a1: L.open, a2: L.no, url: './?arkadas=1', tag: 'fr-' + d.from }));
});
exports.notifyFeedback = onDocumentCreated('feedback/{id}', async e => {
  const d = e.data && e.data.data(); if (!d) return;
  const admins = await db.collection('admins').get();
  await Promise.all(admins.docs.map(a => sendTo(a.id, L => ({ type: 'feedback', title: L.fbT(d.uname || ''), body: (d.text || L.fbB).slice(0, 120), a1: L.open, a2: L.no, url: './?panel=fb', tag: 'fb' }))));
});
// Yönetici geri bildirime cevap yazınca kullanıcıya bildirim
exports.notifyReply = onDocumentUpdated('feedback/{id}', e => {
  const b = e.data.before.data(), a = e.data.after.data();
  if (!a || !a.reply || a.reply === (b && b.reply) || !a.uid) return;
  return sendTo(a.uid, L => ({ type: 'reply', title: L.rpT, body: a.reply.slice(0, 140), a1: L.open, a2: L.no, url: './?mesaj=1', tag: 'rp-' + e.params.id }));
});
// Her gün eski odaları ve davetleri temizle
exports.cleanup = onSchedule({ schedule: 'every day 04:00', timeZone: 'Europe/Istanbul' }, async () => {
  const now = Date.now(), del = [];
  const rooms = await db.collection('rooms').get();
  rooms.forEach(d => { const r = d.data(), seen = r.hostSeen || 0, made = r.createdAt && r.createdAt.toMillis ? r.createdAt.toMillis() : 0;
    const waitOld = r.status === 'wait' && seen < now - 2 * 3600e3;
    const playOld = r.status === 'play' && Math.max(seen, made, r.phaseAt || 0, r.turnAt || 0) < now - 6 * 3600e3;
    if (waitOld || playOld || Object.keys(r.players || {}).length === 0) del.push(d.ref); });
  const inv = await db.collection('invites').where('at', '<', now - 24 * 3600e3).get(); inv.forEach(d => del.push(d.ref));
  for (let i = 0; i < del.length; i += 400){ const w = db.batch(); del.slice(i, i + 400).forEach(r => w.delete(r)); await w.commit(); }
  console.log('temizlendi', del.length);
});
EOF
sed -i "s/__REGION__/$REGION/" functions/index.js
echo "Paketler yükleniyor (1-2 dakika)..."
(cd functions && npm install --silent --no-audit --no-fund)
echo ""
echo "=== Firebase'e giriş ==="
echo "Birazdan bir bağlantı çıkacak. Bağlantıyı aç, Google hesabınla izin ver, çıkan kodu kopyalayıp buraya yapıştır ve Enter'a bas."
npx -y firebase-tools@13 login --no-localhost
echo ""
echo "=== Sunucu yükleniyor (ilk seferde 3-5 dakika sürebilir) ==="
npx -y firebase-tools@13 deploy --only functions --project $PROJECT --force || {
  echo ""; echo "İlk denemede hata verdi. Google yetkileri yeni açıldığı için olabilir. 1 dakika bekleyip tekrar deniyorum..."; sleep 60
  npx -y firebase-tools@13 deploy --only functions --project $PROJECT --force; }
echo ""
echo "✅ BİTTİ! Bildirim sunucusu kuruldu."
