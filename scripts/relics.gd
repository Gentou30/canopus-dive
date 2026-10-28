class_name Relics

## お守り（持っているだけで効く道具）。絵は assets/images/ui/relics.png（4×3）の icon 番目。
## 効果は tactics.gd が has_relic() で調べて使う。手に入るのは「ぬし」を倒したとき・金の宝箱・お店。

const DEFS := {
	"fang": {"name": "シャチの牙", "icon": 0, "price": 120, "desc": "不意打ちのダメージが3倍になる"},
	"float": {"name": "浮き輪", "icon": 1, "price": 90, "desc": "空気の最大が10ふえる"},
	"coral": {"name": "さんごのお守り", "icon": 2, "price": 100, "desc": "体力の最大が4ふえる"},
	"scale": {"name": "金のうろこ", "icon": 3, "price": 80, "desc": "手に入るコインが1.5倍"},
	"shell": {"name": "貝がらの盾", "icon": 4, "price": 110, "desc": "毎ターン、ダメージを1防ぐ"},
	"board": {"name": "波乗りボード", "icon": 5, "price": 110, "desc": "「泳ぐ」で1マス多く泳げる"},
	"lantern": {"name": "深海ちょうちん", "icon": 6, "price": 120, "desc": "敵の視界が1マス短くなる"},
	"bag": {"name": "大きなかばん", "icon": 7, "price": 130, "desc": "手札が6枚になる"},
	"ribbon": {"name": "ミラのリボン", "icon": 8, "price": 100, "desc": "1回だけ、倒れても体力5で起き上がる"},
	"spiral": {"name": "らせん貝", "icon": 9, "price": 80, "desc": "吹き飛ばして壁にぶつけると、さらに+2"},
	"gill": {"name": "えらぶた", "icon": 10, "price": 90, "desc": "敵を倒すと空気+3"},
	"key": {"name": "星のかぎ", "icon": 11, "price": 90, "desc": "宝箱のカードが強化（＋）済みになる"},
}


static func def(id: String) -> Dictionary:
	return DEFS[id]
