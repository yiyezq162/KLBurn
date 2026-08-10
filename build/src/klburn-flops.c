/*
 * KLBurn CPU 浮点算力测量
 * ============================================================
 *
 * 解一个 N 阶稠密线性方程组（LU 分解，LAPACK 的 dgesv），量出全核浮点算力。
 *
 * 为什么要有它
 * ------------
 * 盘里原来那个 xlinpack_xeon64 是 Intel 发布的二进制，在海光 / AMD 上第一行
 * 就打 "optimized for and runs on only genuine Intel processors" 然后退出。
 * 于是**非 Intel 机器的「CPU 浮点算力」永远测不出来** —— 而那不是那台机器
 * 算不动，是我们这张盘只带了 Intel 版本。
 *
 * 为什么不上 netlib HPL + OpenMPI
 * -------------------------------
 * HPL 必须有一份 HPL.dat，N / NB / P / Q 调不好数字能差 2~3 倍。
 * 而这张盘是**插上就跑、无人值守**的：现场没有人去调那个文件。
 * 一个"要调参才准"的基准放进无人值守的流程里，等于每台机器报一个随机数。
 *
 * 口径：和 LINPACK 是同一套算法、同一个公式
 * -----------------------------------------
 * 解 N 阶方程组的浮点运算次数按 LINPACK 的标准计法：
 *
 *     flops = 2/3 * N^3 + 2 * N^2
 *
 * 除以 dgesv 的用时就是 GFlops。所以这里报出来的数和历史上那些 LINPACK
 * 数字是**同一个口径**，可以直接比。
 *
 * ⚠️ 但**绝对值会比 Intel 的 MKL 版本低一到两成**（OpenBLAS 在 Intel 上
 *    一般能到 MKL 的 80~95%）。这是换了测量方法，不是机器变慢了。
 *    统一用这一个程序的理由：**全系列机器可比**比"某几台报得更高"重要得多，
 *    而且这一项本来就只报数、不判合格（lib/bench.sh 文件头第 1 条）。
 *
 * ⚠️ **本程序不判合格与否，一个阈值都不许加进来。**它只做两件事：
 *    量一个数、验一下解对不对。对不对只用来决定"这个数可信不可信"，
 *    不用来说这台机器行不行。
 *
 * 编译：build/build-cpuflops.sh（链 OpenBLAS，Ubuntu 那份是 DYNAMIC_ARCH
 *      构建，运行时自己认 Zen / Hygon / Intel，不用按 CPU 分别出包）
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* LAPACK 的 Fortran 接口。只用这一个，所以直接声明，不引 lapacke 头文件
 * （少一个编译期依赖，OpenBLAS 的 -dev 包不一定带 lapacke.h）。 */
extern void dgesv_(const int *n, const int *nrhs, double *a, const int *lda,
                   int *ipiv, double *b, const int *ldb, int *info);

/* OpenBLAS 自己的线程数查询。链的就是 OpenBLAS，所以直接用 —— 打印"实际用了
 * 几个线程"比打印我们设的环境变量诚实：设了不生效的情况是存在的。 */
extern int openblas_get_num_threads(void);

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* 固定种子的线性同余，不用 rand()：
 *   1. 每次跑出来的矩阵完全一样，两次测量的差异只来自机器，不来自数据
 *   2. rand() 在多次调用之间有全局状态，将来要并行填充就得改
 * 数值落在 [-0.5, 0.5)，对角线另外加 N 保证矩阵良态 —— 病态矩阵解出来的
 * 残差会很大，那是数值问题，不是 CPU 的问题，不该混进来。 */
static unsigned long long lcg_state = 88172645463325252ULL;

static double lcg_next(void)
{
    lcg_state = lcg_state * 6364136223846793005ULL + 1442695040888963407ULL;
    return (double)((lcg_state >> 11) & 0xFFFFFFFFULL) / 4294967296.0 - 0.5;
}

static void fill(double *a, double *b, int n)
{
    long i, j;
    lcg_state = 88172645463325252ULL;
    for (j = 0; j < n; j++)
        for (i = 0; i < n; i++)
            a[(long)j * n + i] = lcg_next();
    for (i = 0; i < n; i++)
        a[(long)i * n + i] += (double)n;

    /* 右端项取 A 的行和，于是精确解就是全 1 的向量 —— 解完直接看每个分量
     * 离 1 有多远就知道算对没算对，不需要再算一遍 A*x。 */
    for (i = 0; i < n; i++) {
        double s = 0.0;
        for (j = 0; j < n; j++)
            s += a[(long)j * n + i];
        b[i] = s;
    }
}

static void usage(const char *me)
{
    fprintf(stderr,
            "用法: %s [-n 阶数] [-r 重复次数]\n"
            "  -n  问题规模，默认 8000\n"
            "  -r  重复次数，取最好成绩，默认 4\n", me);
}

int main(int argc, char **argv)
{
    int n = 8000, runs = 4, i, c;
    while ((c = getopt(argc, argv, "n:r:h")) != -1) {
        switch (c) {
        case 'n': n = atoi(optarg); break;
        case 'r': runs = atoi(optarg); break;
        default:  usage(argv[0]); return 2;
        }
    }
    if (n < 100 || n > 200000) { fprintf(stderr, "阶数超出范围: %d\n", n); return 2; }
    if (runs < 1 || runs > 100) { fprintf(stderr, "重复次数超出范围: %d\n", runs); return 2; }

    size_t abytes = (size_t)n * (size_t)n * sizeof(double);
    double *a = (double *)malloc(abytes);
    double *b = (double *)malloc((size_t)n * sizeof(double));
    int *ipiv = (int *)malloc((size_t)n * sizeof(int));
    if (!a || !b || !ipiv) {
        /* 内存不够就明说，别装作测过了。调用方（lib/bench.sh）看到非零退出码
         * 和空结果会干净地判 SKIP —— 那是我们这边的事，不是机器的毛病。 */
        fprintf(stderr, "内存不足：需要约 %.1f GiB\n", (double)abytes / 1073741824.0);
        free(a); free(b); free(ipiv);
        return 3;
    }

    printf("KLBurn CPU floating-point throughput\n");
    printf("Method        : LU factorization (LAPACK dgesv), double precision\n");
    printf("Problem size  : %d\n", n);
    printf("Threads       : %d\n", openblas_get_num_threads());
    printf("Matrix memory : %.2f GiB\n", (double)abytes / 1073741824.0);
    printf("Runs          : %d\n\n", runs);
    printf("Run    Time(s)       GFlops     MaxResidual\n");
    fflush(stdout);

    /* LINPACK 的标准计法。用 double 算，N=200000 时 N^3 早就超过 32 位了。 */
    const double flop = 2.0 / 3.0 * (double)n * n * n + 2.0 * (double)n * n;
    double best = 0.0, sum = 0.0, worst_res = 0.0;
    int good = 0;

    for (i = 1; i <= runs; i++) {
        int nrhs = 1, lda = n, ldb = n, info = 0;
        double t0, t1, res = 0.0, gf;
        int k;

        fill(a, b, n);                     /* 造数据的时间不计入 */
        t0 = now_s();
        dgesv_(&n, &nrhs, a, &lda, ipiv, b, &ldb, &info);
        t1 = now_s();

        if (info != 0 || t1 <= t0) {
            printf("%3d          -            -               -   (dgesv info=%d)\n", i, info);
            continue;
        }
        for (k = 0; k < n; k++) {
            double d = fabs(b[k] - 1.0);
            if (d > res) res = d;
        }
        gf = flop / (t1 - t0) / 1e9;
        printf("%3d %10.4f %12.3f  %14.3e\n", i, t1 - t0, gf, res);
        fflush(stdout);

        if (gf > best) best = gf;
        if (res > worst_res) worst_res = res;
        sum += gf;
        good++;
    }

    free(a); free(b); free(ipiv);

    if (good == 0) {
        fprintf(stderr, "没有一次成功的求解\n");
        return 4;
    }

    /* 解算错了的话这个数字没有意义，宁可不报。
     *
     * ⚠️ 这**不是**在判这台机器不合格 —— 残差大可能是 BLAS 版本、可能是
     *    内存不够导致的换页、也可能真是 CPU 算错了，在这里分不清。
     *    分不清的东西不该去染客户的结论（report-policy 二-5）：
     *    调用方看到没有 "Best GFlops" 这一行就会干净地判 SKIP。
     *    "这颗 CPU 会算错"有专门的判定去抓（lib/validate.sh 的 SDC 诊断）。
     *
     * 阈值 1e-6 是**数值有效性**的界，不是性能门槛：全 1 的精确解、良态矩阵、
     * 双精度，正常残差在 1e-12 量级，差六个数量级就说明这一轮的解根本不能用。 */
    if (worst_res > 1e-6) {
        fprintf(stderr, "残差过大（%.3e），本轮结果不可信，不报数\n", worst_res);
        return 5;
    }

    printf("\nBest GFlops   : %.3f\n", best);
    printf("Average GFlops: %.3f\n", sum / good);
    printf("Max residual  : %.3e\n", worst_res);
    return 0;
}
