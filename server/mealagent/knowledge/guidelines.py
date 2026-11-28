"""膳食指南知识卡片（RAG 语料）。内容是对公开资料的转述和要点整理，每张卡片都标明出处，agent 引用时附上卡片 id。"""

SRC_2022 = "《中国居民膳食指南（2022）》，中国营养学会"
URL_PAGODA = "https://news.sina.cn/2022-06-15/detail-imizirau8574621.d.html"
URL_8 = "https://www.peopleapp.com/rmharticle/30027604152"
URL_AMOUNTS = "https://finance.sina.cn/2022-05-04/detail-imcwipii7958967.d.html"
URL_ELDER = "https://paper.people.com.cn/hwbwap/html/2022-07/29/content_25931541.htm"
URL_ELDER_EN = "https://en.chinacdc.cn/in_focus/202208/t20220804_260666.html"
URL_HEALTHY_CN = "https://www.thepaper.cn/newsDetail_forward_27537680"
URL_ASPCA = "https://www.aspca.org/pet-care/aspca-poison-control/people-foods-avoid-feeding-your-pets"
URL_AVMA = "https://www.avma.org/public/PetCare/Pages/foods-to-avoid.aspx"
URL_HUMANE = "https://www.humaneworld.org/resources/foods-can-be-poisonous-pets"

CARDS = [
    {"id": "G1", "tags": ["adult", "general"], "title": "八条平衡膳食准则",
     "text": "2022 版膳食指南的八条准则：食物多样、合理搭配；吃动平衡、健康体重；多吃蔬果、奶类、全谷、大豆；适量吃鱼、禽、蛋、瘦肉；少盐少油、控糖限酒；规律进餐、足量饮水；会烹会选、会看标签；公筷分餐、杜绝浪费。",
     "source": SRC_2022, "url": URL_8},
    {"id": "G2", "tags": ["adult", "variety"], "title": "食物多样",
     "text": "建议平均每天吃 12 种以上食物、每周 25 种以上；以谷类为主，每天谷类 200–300 克。",
     "source": SRC_2022, "url": URL_8},
    {"id": "G3", "tags": ["adult", "grain"], "title": "谷薯类的量",
     "text": "谷类每天 200–300 克，其中全谷物和杂豆 50–150 克；薯类每天 50–100 克。膳食宝塔里的推荐量指生重。",
     "source": SRC_2022, "url": URL_AMOUNTS},
    {"id": "G4", "tags": ["adult", "veg"], "title": "蔬菜",
     "text": "餐餐有蔬菜，每天不少于 300 克（推荐 300–500 克），其中深色蔬菜（深绿、红、橙、紫色）应占一半。",
     "source": SRC_2022, "url": URL_8},
    {"id": "G5", "tags": ["adult", "fruit"], "title": "水果",
     "text": "天天吃水果，每天 200–350 克新鲜水果，果汁不能代替鲜果。",
     "source": SRC_2022, "url": URL_8},
    {"id": "G6", "tags": ["adult", "dairy"], "title": "奶类",
     "text": "吃各种奶制品，推荐量从过去的 300 克调整为每天 300–500 克（相当于液态奶）。",
     "source": SRC_2022, "url": URL_AMOUNTS},
    {"id": "G7", "tags": ["adult", "protein", "meat", "fish", "egg"], "title": "鱼禽蛋瘦肉",
     "text": "鱼、禽、蛋和瘦肉平均每天共 120–200 克：每天 1 个鸡蛋，每周至少吃 2 次鱼，畜禽瘦肉每周 300–500 克；不必顿顿有肉，但也不要长期不吃。",
     "source": SRC_2022, "url": URL_AMOUNTS},
    {"id": "G8", "tags": ["adult", "salt", "oil"], "title": "少盐少油",
     "text": "成年人每天烹调油不超过 25–30 克，食盐不超过 5 克；除了少放盐，也要少吃隐形高盐的加工食品。",
     "source": SRC_2022, "url": URL_PAGODA},
    {"id": "G9", "tags": ["adult", "sugar", "water"], "title": "控糖与饮水",
     "text": "《健康中国行动》要点：每人每天添加糖不高于 25 克；成年人一般每天喝 7–8 杯水（1500–1700 毫升）；蔬菜和水果每天合计不低于 500 克。",
     "source": "《健康中国行动（2019—2030年）》", "url": URL_HEALTHY_CN},
    {"id": "G10", "tags": ["adult", "activity"], "title": "吃动平衡",
     "text": "每周至少 5 天中等强度身体活动、累计 150 分钟以上；主动身体活动最好每天 6000 步。",
     "source": SRC_2022, "url": URL_8},
    {"id": "E1", "tags": ["elder"], "title": "一般老年人（65–79 岁）",
     "text": "核心推荐：食物品种丰富，动物性食物充足，常吃大豆制品；鼓励和家人一起吃饭，保持食欲；积极户外活动，延缓肌肉衰减，保持适宜体重；定期体检、评估营养状况。",
     "source": SRC_2022 + "·老年人膳食指南", "url": URL_ELDER},
    {"id": "E2", "tags": ["elder", "grain", "veg"], "title": "老年人主食与蔬菜",
     "text": "老年人每天全谷物和杂豆共 50–150 克，主食里可以加小米、荞麦、玉米等粗粮；每餐都要有蔬菜，优先选深色蔬菜。",
     "source": SRC_2022 + "·老年人膳食指南", "url": URL_ELDER_EN},
    {"id": "E3", "tags": ["elder", "soft", "protein"], "title": "高龄老年人（80 岁以上）",
     "text": "核心推荐：食物多样，鼓励多种进食方式；选择质地细软、能量和营养素密度高的食物；多吃鱼禽肉蛋奶和豆，适量蔬菜配水果；关注体重下降，定期营养筛查，预防营养不良。",
     "source": SRC_2022 + "·高龄老年人膳食指南", "url": URL_ELDER},
    {"id": "P1", "tags": ["pet", "dog", "cat", "toxic"], "title": "宠物不能吃的食物",
     "text": "猫狗应避免：巧克力、咖啡和含咖啡因的东西、酒精、生面团；葡萄和葡萄干（可能导致肾衰竭）；洋葱、大蒜、韭菜、葱（损伤红细胞）；夏威夷果；含木糖醇的无糖糖果、口香糖、部分花生酱；牛油果；高盐零食。",
     "source": "ASPCA 动物中毒控制中心 / 美国兽医协会（AVMA）", "url": URL_ASPCA},
    {"id": "P2", "tags": ["pet", "dog", "cat"], "title": "宠物与人类食物",
     "text": "油腻和油炸食物、多数坚果可能引起呕吐腹泻甚至胰腺炎；奶制品可能引起腹泻（宠物乳糖酶少）；生肉生蛋和骨头有风险。人吃的饭菜常含洋葱大蒜和较多盐，不宜直接喂。",
     "source": "ASPCA / AVMA", "url": URL_AVMA},
    {"id": "P3", "tags": ["pet", "safe"], "title": "可以少量分享的食物",
     "text": "不加调味、切成小块时，苹果（去核）、蓝莓、西兰花、香蕉、胡萝卜、草莓、原味爆米花等可以少量分享给宠物；桃、李、樱桃的核有风险。",
     "source": "ASPCA / Humane World for Animals", "url": URL_HUMANE},
]
