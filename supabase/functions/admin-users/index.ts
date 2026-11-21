// POST { users: [{ full_name, phone, outlet_id, position_id, hire_date?, locale? }] }
// -> { results: [{ phone, ok, user_id?, error? }] }
//
// Creates staff accounts from the admin web, one at a time or as a bulk
// spreadsheet import (PRD F4). Sign-in is by phone + OTP (F5), so no password.
// Every new user gets only the Staff role at their outlet (default deny, R4).
import {
  handle, hasGroupPermission, HttpError, json, myPermissions, requireUser, serviceClient, userClient,
} from "../_shared/http.ts";

type NewUser = {
  full_name: string;
  phone: string;
  outlet_id: string | null;
  position_id: string | null;
  hire_date?: string | null;
  locale?: "id" | "en";
};

/** Indonesian numbers in any common form -> E.164 (+62...). */
function normalizePhone(raw: string): string {
  let p = String(raw).replace(/[^\d+]/g, "");
  if (p.startsWith("+")) return p;
  if (p.startsWith("62")) return `+${p}`;
  if (p.startsWith("0")) return `+62${p.slice(1)}`;
  return `+62${p}`;
}

Deno.serve(handle(async (req) => {
  const caller = userClient(req);
  const me = await requireUser(caller);
  const grants = await myPermissions(caller);
  if (!hasGroupPermission(grants, "user.manage")) throw new HttpError(403, "You need the user.manage permission");

  const { users } = await req.json() as { users: NewUser[] };
  if (!Array.isArray(users) || users.length === 0) throw new HttpError(400, "users is empty");
  if (users.length > 500) throw new HttpError(400, "Import at most 500 users at a time");

  const admin = serviceClient();
  const { data: staffRole } = await admin.from("roles").select("id").eq("name", "Staff").single();

  const results = [];
  for (const u of users) {
    const phone = normalizePhone(u.phone ?? "");
    try {
      if (!u.full_name?.trim()) throw new Error("Name is required");
      if (phone.length < 10) throw new Error("Phone number looks wrong");

      const { data: created, error: authErr } = await admin.auth.admin.createUser({
        phone, phone_confirm: true, user_metadata: { full_name: u.full_name },
      });
      if (authErr) throw new Error(authErr.message);
      const userId = created.user.id;

      // Profile is written as the caller so the audit log (F9) records who did it.
      const { error: profErr } = await caller.from("profiles").insert({
        id: userId,
        full_name: u.full_name.trim(),
        phone,
        outlet_id: u.outlet_id || null,
        position_id: u.position_id || null,
        hire_date: u.hire_date || null,
        locale: u.locale ?? "id",
      });
      if (profErr) {
        await admin.auth.admin.deleteUser(userId);
        throw new Error(profErr.message);
      }

      if (u.outlet_id && staffRole) {
        await admin.from("user_roles").insert({
          user_id: userId, role_id: staffRole.id, scope_type: "outlet", scope_id: u.outlet_id, granted_by: me.id,
        });
        // The service role has no auth.uid(); log the actor explicitly.
        await admin.from("admin_audit_log").insert({
          actor_id: me.id, action: "admin-users:grant-staff", table_name: "user_roles", record_id: userId,
          after: { role: "Staff", scope_type: "outlet", scope_id: u.outlet_id },
        });
      }
      results.push({ phone, ok: true, user_id: userId });
    } catch (e) {
      results.push({ phone, ok: false, error: e instanceof Error ? e.message : String(e) });
    }
  }
  return json({ results });
}));
