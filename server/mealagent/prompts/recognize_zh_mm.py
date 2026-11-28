"""多模态 RAG 版识图提示词：在中文 v2 提示词前面加上检索到的参考餐（图片 + 已核实的份量和营养）。"""
from . import recognize_zh

SYSTEM = recognize_zh.SYSTEM


def build(refs: list[str], with_images: bool) -> str:
    if with_images:
        head = (f"第 1 张图是要识别的这一餐。第 2–{len(refs) + 1} 张是从已核实数据库里检索到的外观相似的参考餐，"
                "它们的份量和营养是称量/核实过的：\n")
    else:
        head = "下面是从已核实数据库里检索到的、外观和这一餐相似的参考餐，它们的份量和营养是核实过的：\n"
    ref_lines = "\n".join(f"参考 {i + 1}：{r}" for i, r in enumerate(refs))
    guide = ("\n\n怎么用参考：参考餐和这一餐不一定相同，不要照抄它们的食材。"
             "先比较这一餐和参考在盘子/碗的大小、食物堆的高度和面积上的差别，再据此校准你的克数和热量；"
             "参考里常见但你容易低估的东西（酱汁、油、奶酪、饮料的份量）尤其要对照。\n\n")
    return head + ref_lines + guide + recognize_zh.USER
