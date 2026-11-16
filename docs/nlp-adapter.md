# 宿主侧 NLP 适配器：情感感知与查询扩展

> 结论先说：**NLP 需要，但不进入 MoonBit 核心。** 记忆回廊的核心是记忆/知识
> 引擎；NLP 是宿主的感知与检索辅助层，输出结构化输入，不写权威状态。

## 一、为什么放在宿主侧

- 核心约束：零模型、零网络、零时钟、零线程；模型由外部调用方提供。
- 页面文本、语义判断、查询改写都需要模型/语言资源；把它们放进核心会破坏
  分层与可复现性。
- 因此提供 `scripts/nlp_adapter.py`：一个可替换的宿主适配器，两个子命令：

```
affect  user text -> {valence, arousal, salience, topics, entities}
expand  query     -> {queries: [original, ...]}
```

引擎只消费结构化结果：`evo-observe` 的 salience/valence、`search.queries`。
适配器不写页面、不提交工单、不改变权威目录。

## 二、`affect`：用户文本 → 情感信号

- **lexicon（默认，离线/确定性）**：内置中英情感词、程度词、否定词与主题词；
  计算有界 valence（-1..1）、arousal（0..1）、salience（0..1）、topics。
  适合测试、离线演示与无模型环境；词表小、领域窄，不宣称通用情感分析。
- **llm（可选）**：OpenAI 兼容 `/chat/completions`，要求模型只返回
  `{valence,arousal,salience,topics,entities}` JSON；越界值夹紧，非法结构
  失败关闭。环境变量 `NLP_LLM_ENDPOINT` / `NLP_LLM_MODEL` / `NLP_LLM_API_KEY`。
- 输出含 `text_sha256` 与 `chars`，便于审计与去重；不保存原文。

边界：情感信号是**观察**，不是事实；引擎不因它改写知识，也不把它当成用户
确认。主动模块只把它当作 `evo-observe` 的一个输入。

## 三、`expand`：查询 → 检索查询集

- **lexicon**：内置小同义词表（记忆/来源/青瓷/检索/情感/人格/梦/资料等），
  保留原查询为第一项，最多 8 条；确定性、可测试。
- **llm**：模型返回 1..8 条短查询；非法结构失败关闭。
- 宿主可把 `queries` 传给 `search` 的 `queries` 字段；引擎仍按自己的
  词元/向量检索与预算执行，不因扩展而绕过证据或版本闸。

## 四、接入 daemon

`evo_daemon.py` 新增：

- `--message-file PATH`：宿主维护的、按行分隔的用户消息文件；只读取**完整行**，
  游标（字节偏移）落在 `.corridor/evo-daemon/state.json`，重启不重复消费。
- `--affect-provider lexicon|llm`：消息 → affect 的提供者。
- 每个新消息变成一条 `evo-observe`：`kind=social`、`subject=user`、
  salience/valence 来自适配器；随后才吸收知识张力。
- 消息文件是宿主资产，不是引擎 state；原文不进入引擎，只有结构化信号与哈希。

失败语义：单条消息的模型失败记录在 summary 的 `messages[].error`，不中断
整个 tick；evo 关闭时 daemon 仍然干净停止。

## 五、HanLP：采用与否的结论（续四十六）

**结论：采用，但只作为适配器的可选 provider，不进默认依赖，也不进核心；
且优先 HanLP 1.x（简约版/portable，pyhanlp）。**

- 1.x（首选）：`pip install pyhanlp`（需 Java）。词典驱动、随 Apache-2.0 仓库
  分发、无 PyTorch、无模型下载，够本项目「分词 + 关键词 + 同义替换」的用量；
  完整数据包与更重的语料启用前仍建议自行核对许可。
- 2.x（后备）：`pip install hanlp`（含 PyTorch），模型首次 `hanlp.load` 时按需
  下载；部分训练语料（如 CTB/LDC 系、商业语料）带研究/商用限制，模型级许可
  必须由启用者核对后再加载。本项目不把这些模型捆绑进仓库或 CI。
- 适配器 `--provider hanlp` 自动探测：先 pyhanlp（1.x），再 hanlp（2.x）；
  都未安装时失败关闭。
  - `affect`：分词替代子串匹配（中文词边界更准），词表打分/程度/否定规则不变；
    2.x 且设置 `NLP_HANLP_NER_MODEL` 时加载 NER 填充 `entities`。
  - `expand`：按分词后的词做同义替换，避免子串误替换。
- `scripts/nlp_adapter_hanlp_e2e.py` 在未安装/运行时缺失（如无 Java）时干净
  SKIP（exit 0），可用时验证 provider 契约；模型/数据许可是启用者的责任。

## 六、明确不做

- 不在核心内跑分词模型、情感模型、NER、embedding 或 LLM（宿主 HanLP provider 属适配器，属例外）。
- 不把 lexicon 的情感判断写成页面事实或用户画像。
- 不复制第三方 NLP 代码/词表；内置词表为净室自写、可替换。
- 不宣称通用中文 NLP 能力；领域适配应替换适配器或走 LLM provider。

## 六、后续

- 检索侧：把 `expand` 接入 Web/CLI 的查询入口（宿主层），并记录扩展来源。
- 情感侧：多模态（语音/表情）适配器，同样只输出结构化信号。
- 评估：用固定语料做 lexicon 与 LLM provider 的一致性/偏差对照，报告如实标注。
