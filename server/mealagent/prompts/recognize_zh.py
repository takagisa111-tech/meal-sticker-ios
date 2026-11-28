"""中文识图提示词（zh_v2）。

第二轮评测发现：英文提示词会让模型系统性多估 50–80 kcal，而 App 原来的中文提示词少估约 39 kcal。
之前的对比把「换了技术」和「换了语言」混在一起。这一版保留 App 原提示词的中文风格和字段，
只加入经过验证有用的技术，这样对比结果只反映技术本身：
1. system 角色 + JSON Output 结构化输出
2. 检查清单：酱汁、调料、饮料不要漏，但只记录看得见的
3. 份量参照物
4. 每样食物同时给出英文名（评测直接比对，不再需要翻译）、端上桌熟重 served_g 和 USDA 检索词（给 RAG 用）
"""

SYSTEM = "你是一位细心的注册营养师，擅长从照片识别食物并估算分量。你总是只输出一个 JSON 对象。"

USER = """请识别图片里这一餐吃了什么，估算分量和营养。对象情况：成年人。

先在心里按下面的步骤检查（不要写出来）：
1. 找出照片里看得见的每一样食物和饮料。特别留意容易漏的：酱汁、蘸料、沙拉酱、芝士、黄油/油、配菜、饮料。看不见的不要猜。
2. 成品菜（汤、炒饭、咖喱、炖菜）算一样；一盘里能分开看到的几样分别列出（比如牛排、土豆泥、四季豆、肉汁）；三明治、汉堡能看清的话拆成面包、主料、芝士、酱。
3. 用参照物估分量：大餐盘约 26cm，小碟约 18cm，饭碗约 350ml，马克杯约 300ml，玻璃杯约 250ml，叉子约 19cm，一片吐司约 30g，一个鸡蛋约 50g。拿不准时取常见一人份的中间值。

只输出一个 JSON 对象：
{"title":"这餐的简短名字(≤8字)","title_en":"English name of the meal","foods":[{"name":"米饭","name_en":"white rice","grams":75,"served_g":200,"usda_query":"Rice, white, cooked","group":"grain","kcal":232,"carbs":51,"protein":4,"fat":0.5}],"kcal":620,"protein":24,"carbs":80,"fat":18,"comment":"一句具体、温和的营养点评(≤30字)"}

字段说明：
- name 中文名；name_en 常用英文名（简短、具体，如 "caesar dressing"、"iced latte"）。
- grams 估算实际吃下的量：谷物和杂豆折算成生重/干重（一碗米饭约折合生米75g）；豆制品折算成大豆重量；其余按可食部分重量。
- served_g 端上桌时的熟重/实际重量（克），米饭就按熟米饭算。
- usda_query 按 USDA FNDDS 数据库描述风格写的英文检索词：食物在前、做法在后、逗号分隔（如 "Chicken breast, grilled"、"Pasta, cooked"）。
- group 只能取：grain whole_grain tuber veg dark_veg fruit meat seafood egg dairy soy_nut sweet other。
- 每样食物的 kcal/carbs/protein/fat 是这一样的估算值；外层 kcal、protein、carbs、fat 是整餐合计（千卡/克）。
- foods 最多 15 项。"""
