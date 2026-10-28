class_name Cards

## カードの定義。効果の処理は tactics.gd の play() で行う。
## どのカードも「わざ」として使うか、「泳ぐ」として左上の mv マスだけ泳ぐかを選べる（メタルギア アシッド風）。
## cost: 使うと減る空気。free: 1ターン2回の行動回数を使わない。exhaust: この階では1回だけ。
## target: わざを使うときに選ぶもの
##   "move"  泳げるマス（range マス以内、道なり）
##   "jump"  range マス以内の空いたマス（敵や岩をとびこえる）
##   "adj"   となり（上下左右）の敵
##   "line"  上下左右の向き（その向きのマスをどれかタップ）
##   "spot"  range マス以内の好きなマス（壁でない）
##   "self"  自分（すぐ使う）
## kind: "move" 移動 / "atk" 攻撃 / "skill" 技 / "mira" ミラ / "junk" じゃま（タコの墨）
## rare: 0 ふつう / 1 すこしめずらしい / 2 めずらしい（お店の値段と、出やすさ）
## 強化したカードは id の後ろに "+" が付く（"tail+"）。UP の値で上書きする。

const DEFS := {
	"swim": {"name": "泳ぐ", "cost": 1, "mv": 3, "target": "move", "range": 3, "kind": "move", "icon": 0, "rare": 0,
		"desc": "3マス泳ぐ"},
	"swim2": {"name": "すいすい", "cost": 1, "mv": 4, "target": "move", "range": 5, "kind": "move", "icon": 0, "rare": 0,
		"desc": "5マス泳ぐ"},
	"dash": {"name": "ダッシュ", "cost": 0, "mv": 2, "target": "move", "range": 6, "noise": 3, "kind": "move", "icon": 1, "rare": 0,
		"desc": "6マス泳ぐ\n水音で敵が来る"},
	"current": {"name": "海流", "cost": 0, "mv": 2, "target": "line", "range": 6, "kind": "move", "icon": 17, "rare": 1,
		"desc": "まっすぐ6マス\n流れに乗る"},
	"leap": {"name": "大ジャンプ", "cost": 1, "mv": 2, "target": "jump", "range": 3, "kind": "move", "icon": 11, "rare": 1,
		"desc": "3マス以内へ\n岩も敵もとびこえる"},
	"tail": {"name": "尾びれ打ち", "cost": 1, "mv": 2, "target": "adj", "dmg": 2, "push": true, "kind": "atk", "icon": 3, "rare": 0,
		"desc": "となりの敵に2\n1マス吹き飛ばす"},
	"bite": {"name": "かみつき", "cost": 2, "mv": 1, "target": "adj", "dmg": 4, "kind": "atk", "icon": 16, "rare": 1,
		"desc": "となりの敵に4"},
	"charge": {"name": "シャチの突進", "cost": 2, "mv": 3, "target": "line", "range": 4, "dmg": 3, "push": true, "kind": "atk",
		"icon": 6, "rare": 0, "desc": "ぶつかるまで突進\n当たった敵に3"},
	"bubble": {"name": "泡のブレス", "cost": 1, "mv": 2, "target": "line", "range": 4, "dmg": 1, "stun": 1, "kind": "atk",
		"icon": 4, "rare": 0, "desc": "一直線の敵に1\n1回休みにする"},
	"horn": {"name": "つらぬく角", "cost": 1, "mv": 2, "target": "line", "range": 3, "dmg": 2, "pierce": true, "push": true,
		"kind": "atk", "icon": 18, "rare": 1, "desc": "3マスの敵すべてに2\n吹き飛ばす"},
	"tide": {"name": "引き潮", "cost": 1, "mv": 1, "target": "line", "range": 5, "dmg": 1, "pull": true, "kind": "atk",
		"icon": 19, "rare": 1, "desc": "一直線の敵に1\nとなりまで引きよせる"},
	"pod": {"name": "群れの呼び声", "cost": 2, "mv": 1, "target": "line", "range": 9, "dmg": 2, "pierce": true, "kind": "atk",
		"icon": 8, "rare": 2, "desc": "一直線の敵\nすべてに2"},
	"whirl": {"name": "渦潮", "cost": 2, "mv": 1, "target": "self", "dmg": 1, "kind": "atk", "icon": 7, "rare": 1,
		"desc": "まわり8マスの敵に1\n外へ押し出す"},
	"sonar": {"name": "音波", "cost": 1, "mv": 1, "target": "self", "radius": 2, "stun": 1, "kind": "skill", "icon": 2, "rare": 1,
		"desc": "2マス以内の敵を\n1回休みにする"},
	"hide": {"name": "海藻がくれ", "cost": 1, "mv": 2, "target": "self", "kind": "skill", "icon": 12, "rare": 0,
		"desc": "次のターンまで\nとなり以外から見えない"},
	"curtain": {"name": "泡のカーテン", "cost": 1, "mv": 1, "target": "spot", "range": 3, "kind": "skill", "icon": 20, "rare": 1,
		"desc": "3マス以内に\n海藻のしげみを作る"},
	"shield": {"name": "雷のうろこ", "cost": 1, "mv": 1, "target": "self", "block": 3, "kind": "skill", "icon": 10, "rare": 0,
		"desc": "次のターンまで\nダメージを3防ぐ"},
	"breath": {"name": "深呼吸", "cost": 0, "mv": 1, "target": "self", "air": 6, "exhaust": true, "kind": "skill", "icon": 5, "rare": 0,
		"desc": "空気+6\nこの階では1回だけ"},
	"map": {"name": "宝の地図", "cost": 0, "mv": 1, "target": "self", "coins": 10, "exhaust": true, "kind": "skill", "icon": 22,
		"rare": 1, "desc": "コイン+10\nこの階では1回だけ"},
	"call": {"name": "ミラのきゅっ！", "cost": 0, "mv": 1, "target": "spot", "range": 6, "noise": 4, "kind": "mira", "icon": 13, "rare": 0,
		"desc": "鳴き声で\n敵をおびき寄せる"},
	"wing": {"name": "ミラの羽ばたき", "cost": 0, "mv": 1, "target": "self", "draw": 2, "free": true, "kind": "mira", "icon": 9, "rare": 1,
		"desc": "カードを2枚引く\n行動回数を使わない"},
	"cheer": {"name": "ミラの応援", "cost": 1, "mv": 1, "target": "self", "plays": 2, "exhaust": true, "kind": "mira", "icon": 21,
		"rare": 2, "desc": "行動回数+2\nこの階では1回だけ"},
	"hug": {"name": "ミラのぎゅっ", "cost": 1, "mv": 1, "target": "self", "heal": 4, "exhaust": true, "kind": "mira", "icon": 14, "rare": 1,
		"desc": "体力+4\nこの階では1回だけ"},
	"ink": {"name": "タコの墨", "cost": 0, "mv": 1, "target": "self", "exhaust": true, "kind": "junk", "icon": 23, "rare": 0,
		"desc": "じゃまなカード\n使うと消える"},
}

## 強化（＋）したときに変わる値
const UP := {
	"swim": {"mv": 4, "range": 4, "desc": "4マス泳ぐ"},
	"swim2": {"mv": 5, "range": 6, "desc": "6マス泳ぐ"},
	"dash": {"range": 8, "noise": 2, "desc": "8マス泳ぐ\n水音で敵が来る"},
	"current": {"range": 9, "mv": 3, "desc": "まっすぐ9マス\n流れに乗る"},
	"leap": {"range": 4, "cost": 0, "desc": "4マス以内へ\n岩も敵もとびこえる"},
	"tail": {"dmg": 3, "desc": "となりの敵に3\n1マス吹き飛ばす"},
	"bite": {"dmg": 6, "desc": "となりの敵に6"},
	"charge": {"dmg": 4, "cost": 1, "desc": "ぶつかるまで突進\n当たった敵に4"},
	"bubble": {"dmg": 2, "range": 5, "desc": "一直線の敵に2\n1回休みにする"},
	"horn": {"dmg": 3, "desc": "3マスの敵すべてに3\n吹き飛ばす"},
	"tide": {"dmg": 2, "stun": 1, "desc": "敵に2、引きよせて\n1回休みにする"},
	"pod": {"dmg": 3, "desc": "一直線の敵\nすべてに3"},
	"whirl": {"dmg": 2, "desc": "まわり8マスの敵に2\n外へ押し出す"},
	"sonar": {"radius": 3, "desc": "3マス以内の敵を\n1回休みにする"},
	"hide": {"cost": 0, "free": true, "desc": "次のターンまで隠れる\n行動回数を使わない"},
	"curtain": {"range": 5, "cost": 0, "desc": "5マス以内に\n海藻のしげみを作る"},
	"shield": {"block": 5, "desc": "次のターンまで\nダメージを5防ぐ"},
	"breath": {"air": 10, "desc": "空気+10\nこの階では1回だけ"},
	"map": {"coins": 18, "desc": "コイン+18\nこの階では1回だけ"},
	"call": {"range": 9, "free": true, "desc": "鳴き声でおびき寄せる\n行動回数を使わない"},
	"wing": {"draw": 3, "desc": "カードを3枚引く\n行動回数を使わない"},
	"cheer": {"cost": 0, "plays": 3, "desc": "行動回数+3\nこの階では1回だけ"},
	"hug": {"heal": 7, "desc": "体力+7\nこの階では1回だけ"},
}

const START_DECK := ["swim", "swim", "swim", "tail", "tail", "bubble", "charge", "hide", "call", "breath"]

## 宝箱・空気だまり・お店に出るカードの候補（同じカードも出る）
const REWARDS := ["swim2", "dash", "current", "leap", "tail", "bite", "charge", "bubble", "horn", "tide", "pod", "whirl",
	"sonar", "hide", "curtain", "shield", "map", "call", "wing", "cheer", "hug"]

## お店の値段（めずらしさごと）
const PRICES := [28, 44, 64]

static var _cache := {}


static func def(id: String) -> Dictionary:
	if _cache.has(id):
		return _cache[id]
	var d: Dictionary
	if id.ends_with("+"):
		var b := base(id)
		d = DEFS[b].duplicate()
		for k in UP.get(b, {}):
			d[k] = UP[b][k]
		d.name = d.name + "+"
		d.up = true
	else:
		d = DEFS[id]
	_cache[id] = d
	return d


static func base(id: String) -> String:
	return id.trim_suffix("+")


static func is_up(id: String) -> bool:
	return id.ends_with("+")


static func can_upgrade(id: String) -> bool:
	return not is_up(id) and UP.has(id)


static func upgraded(id: String) -> String:
	return id + "+" if can_upgrade(id) else id


static func price(id: String) -> int:
	var p: int = PRICES[int(DEFS[base(id)].rare)]
	return p + (16 if is_up(id) else 0)
