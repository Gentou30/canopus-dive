class_name Cards

## カードの定義。効果の処理は dive.gd の play() で行う。
## target: どこを選んで使うか
##   "move"   泳げるマス（range マス以内、道なり）
##   "dive"   真下へまっすぐ（range マスまで）
##   "line"   上下左右の一直線（range マスまで。向きを選ぶ）
##   "adj"    となり（上下左右）の敵
##   "self"   自分（カノープスのマスをタップ／もう一度カードをタップ）
##   "none"   使えない（宝）
## kind: "move" 移動 / "atk" 攻撃 / "skill" 技 / "treasure" 宝

const DEFS := {
	"swim": {"name": "泳ぐ", "cost": 1, "target": "move", "range": 2, "kind": "move", "icon": 0,
		"desc": "2マス泳ぐ"},
	"swim2": {"name": "すいすい", "cost": 1, "target": "move", "range": 3, "kind": "move", "icon": 0,
		"desc": "3マス泳ぐ"},
	"dive": {"name": "急潜行", "cost": 0, "target": "dive", "range": 3, "kind": "move", "icon": 1,
		"desc": "真下に3マスまで\n空気-1"},
	"sonar": {"name": "音波", "cost": 0, "target": "self", "range": 3, "kind": "skill", "icon": 2,
		"desc": "まわり4マスが見える\n近くの敵が起きる"},
	"tail": {"name": "尾びれ打ち", "cost": 1, "target": "adj", "dmg": 2, "kind": "atk", "icon": 3,
		"desc": "となりの敵に2\n1マス吹き飛ばす"},
	"bubble": {"name": "泡のブレス", "cost": 1, "target": "line", "range": 3, "dmg": 1, "kind": "atk", "icon": 4,
		"desc": "一直線3マスに1\n当たった敵は1回休み"},
	"breath": {"name": "深呼吸", "cost": 1, "target": "self", "air": 3, "kind": "skill", "icon": 5, "exhaust": true,
		"desc": "空気+3\nこの階では1回だけ"},
	"charge": {"name": "シャチの突進", "cost": 1, "target": "line", "range": 4, "dmg": 2, "kind": "atk", "icon": 6,
		"desc": "ぶつかるまで突進\n当たった敵に2"},
	"whirl": {"name": "渦潮", "cost": 2, "target": "self", "dmg": 1, "kind": "atk", "icon": 7,
		"desc": "まわり8マスの敵に1\n外へ押し出す"},
	"pod": {"name": "群れの呼び声", "cost": 2, "target": "line", "range": 9, "dmg": 2, "kind": "atk", "icon": 8,
		"desc": "一直線の敵すべてに2"},
	"wing": {"name": "ミラの羽ばたき", "cost": 0, "target": "self", "kind": "skill", "icon": 9,
		"desc": "カードを2枚引く"},
	"spark": {"name": "雷のうろこ", "cost": 1, "target": "self", "kind": "skill", "icon": 10,
		"desc": "このターン受ける\nダメージを0にする"},
	"rise": {"name": "ひと息", "cost": 1, "target": "self", "air": 2, "kind": "skill", "icon": 11,
		"desc": "空気+2\nカードを1枚引く"},
	# 宝。手札をふさぐが、持ち帰ると点になる
	"coin": {"name": "金貨", "cost": -1, "target": "none", "kind": "treasure", "value": 10, "obj": 1,
		"desc": "使えない\n持ち帰ると10"},
	"pearl": {"name": "真珠", "cost": 0, "target": "self", "kind": "treasure", "value": 15, "air": 4, "obj": 2,
		"desc": "持ち帰ると15\n使うと空気+4で消える"},
	"gem": {"name": "青い宝石", "cost": -1, "target": "none", "kind": "treasure", "value": 40, "obj": 3,
		"desc": "使えない\n持ち帰ると40"},
}

const START_DECK := ["swim", "swim", "swim", "swim", "tail", "tail", "bubble", "sonar", "sonar", "breath"]

## 空気だまりでもらえるカードの候補
const REWARDS := ["swim2", "dive", "charge", "whirl", "pod", "wing", "spark", "rise", "bubble", "tail", "sonar"]


static func def(id: String) -> Dictionary:
	return DEFS[id]


static func is_treasure(id: String) -> bool:
	return DEFS[id].kind == "treasure"
