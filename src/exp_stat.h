/*
 * exp_stat.h
 * Cosmos+ OpenSSD �럩�썾�뼱�슜 �떎�뿕 怨꾩륫 紐⑤뱢 (discard 諛⑹떇怨� GC 鍮꾧탳 �떎�뿕)
 *
 * �씠 �뙆�씪�쓣 異붽��븯�뒗 寃껊쭔�쑝濡쒕뒗 �븘臾닿쾬�룄 痢≪젙�릺吏� �븡�뒗�떎.
 * 湲곗〈 �럩�썾�뼱�쓽 �빐�떦 �룞�옉 吏��젏�뿉 exp_on_*() �샇異쒖쓣 �븳 以꾩뵫 �꽔�뼱�빞 �븳�떎.
 * �꽔�쓣 �쐞移섏� 二쇱쓽�궗�빆�� INTEGRATION.md 李멸퀬.
 *
 * �꽕怨� �썝移�
 *  - 紐⑤뱺 移댁슫�꽣�뒗 64鍮꾪듃 �늻�쟻媛믪씠�떎. 痢≪젙 �떆�옉怨� �걹�쓽 李⑥씠濡� 怨꾩궛�븳�떎.
 *  - 留� �럹�씠吏�留덈떎 UART濡� 異쒕젰�븯吏� �븡�뒗�떎. 異쒕젰�� 二쇨린�쟻 �삉�뒗 留덉빱 紐낅졊 �븣留� �븳�떎.
 *  - �떒�쐞�뒗 紐⑤몢 諛붿씠�듃(�삉�뒗 �슏�닔, tick)�떎. �샇異쒗븯�뒗 履쎌뿉�꽌 �럹�씠吏�쨌�뒳�씪�씠�뒪 �닔瑜�
 *    諛붿씠�듃濡� 諛붽퓭�꽌 �꽆湲대떎. �씠�젃寃� �빐�빞 留ㅽ븨 �떒�쐞媛� �떖�씪�룄 �빐�꽍�씠 媛숇떎.
 */
#ifndef EXP_STAT_H_
#define EXP_STAT_H_

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned long long exp_u64;
typedef unsigned int       exp_u32;

/* ---------- �꽕�젙 ---------- */

/* 二쇨린�쟻 UART 異쒕젰 媛꾧꺽(珥�). 0�씠硫� 二쇨린 異쒕젰�쓣 �걟�떎(留덉빱 紐낅졊�쑝濡쒕쭔 異쒕젰). */
#ifndef EXP_STAT_PRINT_PERIOD_SEC
#define EXP_STAT_PRINT_PERIOD_SEC 10
#endif

/* NAND program �썝�씤 援щ텇 */
typedef enum {
    EXP_PROG_HOST = 0,   /* host write濡� �씤�븳 program */
    EXP_PROG_GC   = 1,   /* GC �쑀�슚 �뜲�씠�꽣 �씠�룞�쑝濡� �씤�븳 program */
    EXP_PROG_META = 2,   /* 留ㅽ븨 �뀒�씠釉� �벑 硫뷀��뜲�씠�꽣 program */
    EXP_PROG_NR
} exp_prog_cause_t;

/* ---------- 移댁슫�꽣 臾띠쓬 ---------- */
typedef struct {
    /* 痢≪젙 �빆紐�: Host �벐湲� 諛붿씠�듃 (NVMe �벐湲� 紐낅졊 泥섎━) */
    exp_u64 host_write_bytes;
    exp_u64 host_write_cmds;

    /* 痢≪젙 �빆紐�: GC 蹂듭궗 諛붿씠�듃 (GC媛� �쑀�슚 �뜲�씠�꽣瑜� �씠�룞�븯�뒗 泥섎━) */
    exp_u64 gc_copy_bytes;

    /* 痢≪젙 �빆紐�: GC �슏�닔 (victim�쓽 蹂듭궗/erase �슂泥� �깮�꽦�쓣 留덉튇 �떆�젏; �셿猷� �븘�떂) */
    exp_u64 gc_count;
    exp_u64 gc_victim_valid_bytes;   /* �슂泥��쓣 �깮�꽦�븳 victim�뱾�쓽 �쑀�슚 �뜲�씠�꽣 �빀 */

    /* 痢≪젙 �빆紐�: Erase �슏�닔 (NAND 釉붾줉 �궘�젣 泥섎━) */
    exp_u64 erase_issued; /* �뱶�씪�씠踰� erase �샇異� �슏�닔 */
    exp_u64 erase_count;
    exp_u64 erase_fail;

    /* 痢≪젙 �빆紐�: DSM 紐낅졊 �닔 (Dataset Management 紐낅졊 �닔�떊) */
    exp_u64 dsm_cmd_count;
    exp_u64 dsm_range_count;
    exp_u64 dsm_req_bytes;           /* �샇�뒪�듃媛� �슂泥��븳 踰붿쐞�쓽 �빀 */

    /* 痢≪젙 �빆紐�: DSM�쑝濡� �깉濡� 臾댄슚�솕�븳 諛붿씠�듃 (Deallocate�뿉 �뵲瑜� 留ㅽ븨 臾댄슚�솕) */
    exp_u64 dsm_invalid_bytes;       /* �씠�쟾�뿉 �쑀�슚�뻽�뜕 �뜲�씠�꽣 以� �씠踰덉뿉 臾댄슚�솕�븳 �뼇 */
    exp_u64 dsm_ignored_bytes;       /* 遺�遺� 留ㅽ븨 �떒�쐞 �벑�쑝濡� 臾댁떆�븳 �뼇 */
    exp_u64 dsm_already_free_bytes;  /* �씠誘� 臾댄슚�씠嫄곕굹 湲곕줉�맂 �쟻 �뾾�뒗 踰붿쐞 */

    /* 痢≪젙 �빆紐�: DSM 泥섎━ �떆媛� (�젙�빐吏� DSM 泥섎━ 援ш컙�쓽 �떆�옉쨌醫낅즺) */
    exp_u64 dsm_ticks_total;
    exp_u64 dsm_ticks_max;

    /* WAF 怨꾩궛�슜: NAND program 諛붿씠�듃瑜� �썝�씤蹂꾨줈 */
    exp_u64 nand_prog_bytes[EXP_PROG_NR];

    /* 怨꾩륫 �옄泥� �젏寃� */
    exp_u64 dsm_nesting_error;       /* begin �뾾�씠 end, �삉�뒗 begin 以묐났 */
    exp_u64 epoch; /* reset 寃쎄퀎 �떇蹂� */
    exp_u64 dump_seq;                /* 異쒕젰 �씪�젴踰덊샇 */
} exp_stat_t;

/* 紐⑤뱺 媛깆떊/異쒕젰�� �떒�씪 NVMe 硫붿씤 �떎�뻾 �쓲由꾩뿉�꽌留� �샇異�. ISR/�떎瑜� 肄붿뼱 湲덉�. */
extern exp_stat_t g_exp_stat;

/* ---------- 珥덇린�솕쨌異쒕젰 ---------- */

/* �럩�썾�뼱 珥덇린�솕 �걹 臾대졄 �븳 踰� �샇異� */
void exp_stat_init(void);

/* 紐⑤뱺 移댁슫�꽣瑜� 0�쑝濡�. 痢≪젙留덈떎 由ъ뀑�븯吏� �븡怨� 李⑤텇�쑝濡� 怨꾩궛�븯�뒗 寃껋쓣 沅뚯옣 */
void exp_stat_reset(void);

/* �쁽�옱 媛믪쓣 UART�뿉 �븳 以꾨줈 異쒕젰. tag�뒗 "PERIOD", "MARK", "BOOT" �벑 */
void exp_stat_dump(const char *tag);

/* 硫붿씤 猷⑦봽�뿉�꽌 留ㅻ쾲 �샇異�. 二쇨린媛� �릺硫� exp_stat_dump("PERIOD") */
void exp_stat_poll(void);

/* �샇�뒪�듃媛� 蹂대궦 留덉빱 紐낅졊 泥섎━ (�꽑�깮, INTEGRATION.md 4�젅)
 *   arg = 0 : 異쒕젰留�
 *   arg = 1 : 異쒕젰 �썑 由ъ뀑                                    */
void exp_stat_on_marker(exp_u32 arg);

/* ---------- �룞�옉 吏��젏�뿉 �꽔�쓣 �샇異� ---------- */

/* NVMe �벐湲� 紐낅졊 �븯�굹瑜� 諛쏆븘�뱾�씪 �븣 �븳 踰�. bytes = (NLB + 1) * LBA �겕湲� */
static inline void exp_on_host_write(exp_u64 bytes)
{
    g_exp_stat.host_write_cmds++;
    g_exp_stat.host_write_bytes += bytes;
}

/* GC媛� �쑀�슚 �뜲�씠�꽣 �븳 �떒�쐞瑜� �깉 �쐞移섎줈 �삷湲곕룄濡� �솗�젙�븷 �븣 �븳 踰�.
 * 媛숈� �뜲�씠�꽣�뿉 ���빐 �씫湲� �슂泥�怨� �벐湲� �슂泥� �뼇履쎌뿉�꽌 遺�瑜댁� 留� 寃� */
static inline void exp_on_gc_copy(exp_u64 bytes)
{
    g_exp_stat.gc_copy_bytes += bytes;
}

/* victim �븯�굹�쓽 蹂듭궗/erase �슂泥��쓣 紐⑤몢 �깮�꽦�뻽�쓣 �븣 �븳 踰�. NAND �셿猷� �븘�떂. */
static inline void exp_on_gc_victim_scheduled(exp_u64 victim_valid_bytes)
{
    g_exp_stat.gc_count++;
    g_exp_stat.gc_victim_valid_bytes += victim_valid_bytes;
}

/* �떎�젣 �셿猷� �긽�깭瑜� �솗�씤�븳 寃쎌슦�뿉留� �샇異�. �씠踰� �넻�빀�뿉�꽌�뒗 �뿰寃고븯吏� �븡�쓬. */
static inline void exp_on_erase(int ok)
{
    if (ok) g_exp_stat.erase_count++;
    else    g_exp_stat.erase_fail++;
}

static inline void exp_on_erase_issued(void)
{
    g_exp_stat.erase_issued++;
}

/* NAND program 諛쒗뻾 �븯�굹. �썝�씤怨� �뜲�씠�꽣 �쁺�뿭 諛붿씠�듃 */
static inline void exp_on_nand_program(exp_prog_cause_t cause, exp_u64 bytes)
{
    if ((unsigned)cause < EXP_PROG_NR)
        g_exp_stat.nand_prog_bytes[cause] += bytes;
}

/* DSM 紐낅졊 �븯�굹瑜� 諛쏆븯�쓣 �븣 �븳 踰� (Deallocate �냽�꽦�씠 �뾾�뼱�룄 �꽱�떎) */
static inline void exp_on_dsm_cmd(exp_u32 nranges, exp_u64 req_bytes)
{
    g_exp_stat.dsm_cmd_count++;
    g_exp_stat.dsm_range_count += nranges;
    g_exp_stat.dsm_req_bytes += req_bytes;
}

/* 留ㅽ븨 �떒�쐞 �븯�굹瑜� �떎�젣濡� 臾댄슚�솕�뻽�쓣 �븣(吏곸쟾源뚯� �쑀�슚���뜕 寃쎌슦留�) */
static inline void exp_on_dsm_invalidated(exp_u64 bytes)
{
    g_exp_stat.dsm_invalid_bytes += bytes;
}

/* 遺�遺� 留ㅽ븨 �떒�쐞�씪�꽌 臾댁떆�븳 寃쎌슦 */
static inline void exp_on_dsm_ignored(exp_u64 bytes)
{
    g_exp_stat.dsm_ignored_bytes += bytes;
}

/* �씠誘� 臾댄슚��嫄곕굹 湲곕줉�맂 �쟻 �뾾�뒗 留ㅽ븨 �떒�쐞 */
static inline void exp_on_dsm_already_free(exp_u64 bytes)
{
    g_exp_stat.dsm_already_free_bytes += bytes;
}

/* DSM 泥섎━ �떆媛� 痢≪젙. �븳 DSM 紐낅졊�쓽 泥섎━ �떆�옉怨� �걹�뿉�꽌 �븳 踰덉뵫.
 * �몢 �샇異� �궗�씠�뿉 return 寃쎈줈媛� �뿬�윭 媛쒕㈃ 紐⑤뱺 寃쎈줈�뿉�꽌 end瑜� 遺�瑜� 寃� */
void exp_dsm_begin(void);
void exp_dsm_end(void);

#ifdef __cplusplus
}
#endif

#endif /* EXP_STAT_H_ */
