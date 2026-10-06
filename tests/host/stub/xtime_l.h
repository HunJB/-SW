/* stand-in for the Xilinx BSP header, PC build only */
typedef unsigned long long XTime;
#define COUNTS_PER_SECOND 333333343ULL
void XTime_GetTime(XTime *t);
void XTime_SetTime(XTime t);
