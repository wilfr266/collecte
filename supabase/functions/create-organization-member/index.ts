// Création d'un compte collecteur ou client par l'administrateur de son organisation.
//
// Le mobile ne permet pas de s'inscrire : sans cette fonction, un nouveau collecteur ne peut
// pas obtenir de compte. La clé service_role reste côté serveur (variable d'environnement de
// l'Edge Function) ; Terenza Admin n'envoie que le jeton de session de l'administrateur.
//
// 1. Jeton vérifié auprès de Supabase Auth ; profil actif et permissions profile.manage +
//    role.assign vérifiés dans SON organisation (jamais une organisation envoyée par le client).
// 2. Compte Auth créé avec l'adresse marquée confirmée (aucun email envoyé : pas de limite
//    d'envoi) et un mot de passe initial transmis au collecteur, qu'il change ensuite.
// 3. register_created_member (service_role uniquement) rattache le compte, attribue le rôle et
//    journalise ; en cas d'échec, le compte Auth créé est supprimé (aucun compte orphelin).
// 4. Option `taxpayerId` (rôle client) : link_client_taxpayer, appelée avec le jeton de
//    l'administrateur (droits revérifiés), lie le compte à sa fiche client. Un échec n'annule
//    pas le compte : la réponse le signale (linked: false) et le lien se refait dans Terenza Admin.

import { createClient } from 'npm:@supabase/supabase-js@2'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const ROLES = new Set(['collector', 'client'])
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } })
}

/** Clé serveur : variable historique, sinon clé secrète du nouveau format. */
function serviceKey(): string | undefined {
  const legacy = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (legacy) return legacy
  try {
    const keys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}') as Record<string, string>
    return keys.default ?? Object.values(keys)[0]
  } catch {
    return undefined
  }
}

function publicKey(): string | undefined {
  const legacy = Deno.env.get('SUPABASE_ANON_KEY')
  if (legacy) return legacy
  try {
    const keys = JSON.parse(Deno.env.get('SUPABASE_PUBLISHABLE_KEYS') ?? '{}') as Record<string, string>
    return keys.default ?? Object.values(keys)[0]
  } catch {
    return undefined
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS })
  if (req.method !== 'POST') return reply(405, { code: 'method_not_allowed' })

  const url = Deno.env.get('SUPABASE_URL')
  const anon = publicKey()
  const service = serviceKey()
  const authorization = req.headers.get('Authorization')
  if (!url || !anon || !service) return reply(500, { code: 'server_misconfigured' })
  if (!authorization?.startsWith('Bearer ')) return reply(401, { code: 'unauthenticated' })

  let body: { email?: unknown; displayName?: unknown; phone?: unknown; roleKey?: unknown; password?: unknown; taxpayerId?: unknown }
  try {
    body = await req.json()
  } catch {
    return reply(400, { code: 'invalid_body' })
  }
  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : ''
  const displayName = typeof body.displayName === 'string' ? body.displayName.trim() : ''
  const phone = typeof body.phone === 'string' ? body.phone.trim() : ''
  const roleKey = typeof body.roleKey === 'string' ? body.roleKey : ''
  const password = typeof body.password === 'string' ? body.password : ''
  const taxpayerId = typeof body.taxpayerId === 'string' && body.taxpayerId !== '' ? body.taxpayerId : null
  if (!EMAIL.test(email) || displayName.length < 2 || displayName.length > 120 || !ROLES.has(roleKey)
    || password.length < 10 || password.length > 72 || phone.length > 30
    || (taxpayerId !== null && (roleKey !== 'client' || !UUID.test(taxpayerId)))) {
    return reply(400, { code: 'invalid_input' })
  }

  // Appelant : jeton validé par Supabase Auth, droits vérifiés par les fonctions du schéma.
  const asCaller = createClient(url, anon, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const { data: caller, error: callerError } = await asCaller.auth.getUser()
  if (callerError || !caller.user) return reply(401, { code: 'unauthenticated' })

  const { data: profile } = await asCaller.from('profiles').select('organization_id, status').eq('id', caller.user.id).maybeSingle()
  const organizationId = profile?.status === 'active' ? (profile.organization_id as string | null) : null
  if (!organizationId) return reply(403, { code: 'forbidden' })
  for (const permission of ['profile.manage', 'role.assign']) {
    const { data: allowed } = await asCaller.rpc('has_permission', { p_organization_id: organizationId, p_permission_key: permission })
    if (allowed !== true) return reply(403, { code: 'forbidden' })
  }

  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { display_name: displayName },
  })
  if (createError || !created.user) {
    const code = createError?.code === 'email_exists' || createError?.status === 422 ? 'email_exists'
      : createError?.code === 'weak_password' ? 'weak_password'
      : 'create_failed'
    return reply(code === 'create_failed' ? 500 : 409, { code })
  }

  const { error: registerError } = await admin.rpc('register_created_member', {
    p_actor_id: caller.user.id,
    p_user_id: created.user.id,
    p_role_key: roleKey,
    p_phone: phone || null,
  })
  if (registerError) {
    // Trace serveur (journaux de l'Edge Function) : jamais le mot de passe.
    console.error('register_created_member failed', { userId: created.user.id, code: registerError.code })
    const { error: deleteError } = await admin.auth.admin.deleteUser(created.user.id)
    if (deleteError) {
      // Compte Auth orphelin (profil pending, sans organisation) : rattachable ensuite via
      // « Rattacher un compte existant » ; signalé pour reprise manuelle.
      console.error('orphan auth account after rollback failure', { userId: created.user.id, code: deleteError.code })
    }
    return reply(registerError.code === '42501' ? 403 : 500, { code: registerError.code === '42501' ? 'forbidden' : 'register_failed' })
  }

  if (taxpayerId) {
    const { error: linkError } = await asCaller.rpc('link_client_taxpayer', { p_user_id: created.user.id, p_taxpayer_id: taxpayerId })
    if (linkError) {
      console.error('link_client_taxpayer failed', { userId: created.user.id, code: linkError.code })
      return reply(200, { userId: created.user.id, linked: false })
    }
    return reply(200, { userId: created.user.id, linked: true })
  }

  return reply(200, { userId: created.user.id })
})
