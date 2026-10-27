class_name Cards

## カードの定義。効果の処理は tactics.gd の play() で行う。
## どのカードも「わざ」として使うか、「泳ぐ」として左上の mv マスだけ泳ぐかを選べる（メタルギア アシッド風）。
## cost: 使うと減る空気。free: 1ターン2回の行動回数を使わない。exhaust: この階では1回だけ。
## target: わざを使うときに選ぶもの
##   "move"  泳げるマス（range マス以内、道なり）
##   "adj"   となり（上下左右）の敵
##   "line"  上下左右の向き（その向きのマスをどれかタップ）
##   "spot"  range マス以内の好きなマス（壁でない）
##   "self"  自分（すぐ使う）
## kind: "move" 移動 / "atk" 攻撃 / "skill" 技 / "mira" ミラ

const DEFS := {
	"swim": {"name": "泳ぐ", "cost": 1, "mv": 3, "target": "move", "range": 3, "kind": "move", "icon": 0,
		"desc": "3マス泳ぐ"},
	"swim2": {"name": "すいすい", "cost": 1, "mv": 4, "target": "move", "range": 5, "kind": "move", "icon": 0,
		"desc": "5マス泳ぐ"},
	"dash": {"name": "ダッシュ", "cost": 0, "mv": 2, "target": "move", "range": 6, "noise": 3, "kind": "move", "icon": 1,
		"desc": "6マス泳ぐ\n水音で敵が来る"},
	"tail": {"name": "尾びれ打ち", "cost": 1, "mv": 2, "target": "adj", "dmg": 2, "push": true, "kind": "atk", "icon": 3,
		"desc": "となりの敵に2\n1マス吹き飛ばす"},
	"charge": {"name": "シャチの突進", "cost": 2, "mv": 3, "target": "line", "range": 4, "dmg": 3, "push": true, "kind": "atk",
		"icon": 6, "desc": "ぶつかるまで突進\n当たった敵に3"},
	"bubble": {"name": "泡のブレス", "cost": 1, "mv": 2, "target": "line", "range": 4, "dmg": 1, "stun": 1, "kind": "atk",
		"icon": 4, "desc": "一直線の敵に1\n1回休みにする"},
	"pod": {"name": "群れの呼び声", "cost": 2, "mv": 1, "target": "line", "range": 9, "dmg": 2, "pierce": true, "kind": "atk",
		"icon": 8, "desc": "一直線の敵\nすべてに2"},
	"whirl": {"name": "渦潮", "cost": 2, "mv": 1, "target": "self", "dmg": 1, "kind": "atk", "icon": 7,
		"desc": "まわり8マスの敵に1\n外へ押し出す"},
	"sonar": {"name": "音波", "cost": 1, "mv": 1, "target": "self", "radius": 2, "stun": 1, "kind": "skill", "icon": 2,
		"desc": "2マス以内の敵を\n1回休みにする"},
	"hide": {"name": "海藻がくれ", "cost": 1, "mv": 2, "target": "self", "kind": "skill", "icon": 12,
		"desc": "次のターンまで\nとなり以外から見えない"},
	"shield": {"name": "雷のうろこ", "cost": 1, "mv": 1, "target": "self", "block": 3, "kind": "skill", "icon": 10,
		"desc": "次のターンまで\nダメージを3防ぐ"},
	"breath": {"name": "深呼吸", "cost": 0, "mv": 1, "target": "self", "air": 6, "exhaust": true, "kind": "skill", "icon": 5,
		"desc": "空気+6\nこの階では1回だけ"},
	"call": {"name": "ミラのきゅっ！", "cost": 0, "mv": 1, "target": "spot", "range": 6, "noise": 4, "kind": "mira", "icon": 13,
		"desc": "鳴き声で\n敵をおびき寄せる"},
	"wing": {"name": "ミラの羽ばたき", "cost": 0, "mv": 1, "target": "self", "draw": 2, "free": true, "kind": "mira", "icon": 9,
		"desc": "カードを2枚引く\n行動回数を使わない"},
	"hug": {"name": "ミラのぎゅっ", "cost": 1, "mv": 1, "target": "self", "heal": 4, "exhaust": true, "kind": "mira", "icon": 14,
		"desc": "体力+4\nこの階では1回だけ"},
}

const START_DECK := ["swim", "swim", "swim", "tail", "tail", "bubble", "charge", "hide", "call", "breath"]

## 宝箱・空気だまりでもらえるカードの候補（同じカードも出る）
const REWARDS := ["swim2", "dash", "tail", "charge", "bubble", "pod", "whirl", "sonar", "hide", "shield", "call", "wing", "hug"]


static func def(id: String) -> Dictionary:
	return DEFS[id]
