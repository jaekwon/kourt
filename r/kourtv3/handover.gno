package kourtv3

// HandOver moves every seat the caller holds by virtue of having deployed or
// founded, to another address, in one transaction.
//
// WHY ONE VERB AND NOT THREE. AddPackage fixes the deployer as the global DAO
// admin (init founds the meta court with the deployer as its creator, and the
// first creator becomes directoryAdmin, which ensureGlobalDAO copies into the
// admin seat). The realm is deployed from whatever key can sign unattended —
// a hot key on a laptop — and a hot key must not stay the owner of pricing,
// moderation, the burn share and the meta court's moderator bench. So the
// hand-off has to be complete, and it has to be complete in a single call:
// TransferGlobalAdmin moves the admin seat and nothing else, leaving the old
// key seated as a DAO MEMBER (a vote in every m-of-n), still the creator of
// the meta court (its 1-of-1 moderator until an election, and the appointment
// power), and still what DirectoryAdmin() reports. Three separate calls would
// leave the realm in a half-handed state between them, and there is no second
// deployer to notice.
//
// What moves: the global DAO admin seat (the successor is seated first, then
// the caller is UNSEATED — the mirror of RemoveGlobalMod, which the admin
// cannot apply to itself); directoryAdmin, so the read and the DAO agree; and
// for every court the caller founded, the creator seat and, where a moderator
// set exists and no election has unseated the creator, the moderator seat.
// Courts founded by others are untouched: this is a hand-over of what the
// caller holds, not a takeover. Banked approvals are cleared wherever a
// member set changed, as every membership change here does.
//
// Repeatable on purpose: the successor can hand over again, so a ledger key
// that later moves to a multisig is not stranded.
func HandOver(cur realm, to address) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	if !to.IsValid() {
		panic("kourtv3: not a valid address")
	}
	who := cur.Previous().Address()
	d := ensureGlobalDAO()
	if who != d.admin {
		panic("kourtv3: only the global DAO admin hands over")
	}
	if to == who {
		panic("kourtv3: hand over to a different address")
	}
	seatGlobalMember(d, to)
	d.admin = to
	if d.members.Has(who.String()) {
		d.members.Remove(who.String())
		d.n--
		if d.purgeM > d.n {
			d.purgeM = d.n
		}
		clearPendingOnMembershipChange(&d.pending)
	}
	directoryAdmin = to
	courts.Iterate("", "", func(_ string, v any) bool {
		c := v.(*Court)
		if c.admin != who {
			return false
		}
		c.admin = to
		if cm := c.mod; cm != nil && !cm.creatorUnseated {
			if cm.members.Has(who.String()) {
				cm.members.Remove(who.String())
				cm.n--
			}
			if !cm.members.Has(to.String()) {
				cm.members.Set(to.String(), true)
				cm.n++
			}
			if cm.m > cm.n {
				cm.m = cm.n
			}
			clearPendingOnMembershipChange(&cm.pending)
		}
		return false
	})
}
