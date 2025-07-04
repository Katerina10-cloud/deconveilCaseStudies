setwd("/Users/katsiarynadavydzenka/Documents/PhD_AI/deconveilCaseStudies/")

pkgs <- c("tidyverse", "ggplot2", "ggpubr", "patchwork", "openxlsx")
sapply(pkgs, require, character.only = TRUE)
source("utils/utils_plot.R")

### Test Robustness of DeConveil to CNV noise ###

base_path <- "simulations/results/simulation_4"
lfc_cut <- 1.0
pval_cut <- 0.05
noise_levels <- c("no_noise", "noise_10", "noise_15", "noise_20", "noise_25")
sample_sizes <- c(10, 20, 40, 60)
n_genes <- 5000
replicates <- 1:5

get_de_type <- function(logfc, pval, lfc_cut, pval_cut) {
  case_when(
    pval < pval_cut & logfc > lfc_cut ~ "Up-reg",
    pval < pval_cut & logfc < -lfc_cut ~ "Down-reg",
    TRUE ~ "n.s."
  )
}

load_and_classify <- function(path) {
  read.csv(path, row.names = 1) %>%
    tibble::rownames_to_column("gene") %>%  # Move rownames to a proper column
    mutate(
      DEtype = get_de_type(log2FoldChange, padj, lfc_cut, pval_cut)
    ) %>%
    select(gene, log2FoldChange, padj, DEtype)
}

# Process a single configuration
process_one_replicate <- function(noise, replicate, sample_size) {
  # Skip clean dataset, it's used as baseline
  if (noise == "no_noise") return(NULL)
  
  # File paths
  clean_naive_path <- file.path(base_path, "no_noise", "replicates_pydeseq", paste0(replicate, "_res_CNnaive_", sample_size, "_", n_genes, ".csv"))
  clean_aware_path <- file.path(base_path, "no_noise", "replicates_deconveil", paste0(replicate, "_res_CNaware_", sample_size, "_", n_genes, ".csv"))
  
  noisy_naive_path <- file.path(base_path, noise, "replicates_pydeseq", paste0(replicate, "_res_CNnaive_", sample_size, "_", n_genes, ".csv"))
  noisy_aware_path <- file.path(base_path, noise, "replicates_deconveil", paste0(replicate, "_res_CNaware_", sample_size, "_", n_genes, ".csv"))
  
  if (!file.exists(clean_naive_path) || !file.exists(clean_aware_path) ||
      !file.exists(noisy_naive_path) || !file.exists(noisy_aware_path)) {
    message("⚠️ Missing file for replicate ", replicate, " | Noise: ", noise, " | Sample size: ", sample_size)
    return(NULL)
  }
  
  # Read and annotate data
  clean_naive <- read.csv(clean_naive_path, row.names = 1) %>%
    rownames_to_column("gene") %>%
    mutate(DEtype_clean_naive = get_de_type(log2FoldChange, padj, lfc_cut, pval_cut)) %>%
    select(gene, log2FoldChange, padj, DEtype_clean_naive) %>%
    rename(logFC_clean_naive = log2FoldChange, pval_clean_naive = padj)
  
  clean_aware <- read.csv(clean_aware_path, row.names = 1) %>%
    rownames_to_column("gene") %>%
    mutate(DEtype_clean_aware = get_de_type(log2FoldChange, padj, lfc_cut, pval_cut)) %>%
    select(gene, log2FoldChange, padj, DEtype_clean_aware) %>%
    rename(logFC_clean_aware = log2FoldChange, pval_clean_aware = padj)
  
  noisy_naive <- read.csv(noisy_naive_path, row.names = 1) %>%
    rownames_to_column("gene") %>%
    mutate(DEtype_noisy_naive = get_de_type(log2FoldChange, padj, lfc_cut, pval_cut)) %>%
    select(gene, log2FoldChange, padj, DEtype_noisy_naive) %>%
    rename(logFC_noisy_naive = log2FoldChange, pval_noisy_naive = padj)
  
  noisy_aware <- read.csv(noisy_aware_path, row.names = 1) %>%
    rownames_to_column("gene") %>%
    mutate(DEtype_noisy_aware = get_de_type(log2FoldChange, padj, lfc_cut, pval_cut)) %>%
    select(gene, log2FoldChange, padj, DEtype_noisy_aware) %>%
    rename(logFC_noisy_aware = log2FoldChange, pval_noisy_aware = padj)
  
  # Merge all results
  df <- clean_naive %>%
    inner_join(clean_aware, by = "gene") %>%
    inner_join(noisy_naive, by = "gene") %>%
    inner_join(noisy_aware, by = "gene")
  
  # Classify gene groups
  df <- df %>%
    mutate(
      group_clean = case_when(
        DEtype_clean_naive %in% c("Up-reg", "Down-reg") & DEtype_clean_aware == "n.s." ~ "DSG",
        DEtype_clean_naive == DEtype_clean_aware & DEtype_clean_naive != "n.s." ~ "DIG",
        DEtype_clean_naive == "n.s." & DEtype_clean_aware %in% c("Up-reg", "Down-reg") ~ "DCG",
        TRUE ~ "non_DEG"
      ),
      group_noise = case_when(
        DEtype_noisy_naive %in% c("Up-reg", "Down-reg") & DEtype_noisy_aware == "n.s." ~ "DSG",
        DEtype_noisy_naive == DEtype_noisy_aware & DEtype_noisy_naive != "n.s." ~ "DIG",
        DEtype_noisy_naive == "n.s." & DEtype_noisy_aware %in% c("Up-reg", "Down-reg") ~ "DCG",
        TRUE ~ "non_DEG"
      ),
      group_changed = group_clean != group_noise
    )
  
  # Compute summary stats per group
  result <- df %>%
    group_by(group_clean) %>%
    summarise(
      n_clean = n(),
      n_noisy = sum(group_clean == group_noise),
      n_overlap = sum(group_clean == group_noise & group_clean == cur_group()$group_clean),
      n_union = sum(group_clean == cur_group()$group_clean | group_noise == cur_group()$group_clean),
      Jaccard_index = n_overlap / n_union,
      log2FC_corr = cor(logFC_clean_aware, logFC_noisy_aware, method = "pearson"),
      pval_corr = cor(pval_clean_aware, pval_noisy_aware, method = "spearman"),
      .groups = "drop"
    ) %>%
    mutate(
      noise_level = noise,
      replicate = replicate,
      sample_size = sample_size
    )
  return(result)
}

all_results <- purrr::cross_df(list(
  noise = noise_levels[noise_levels != "no_noise"],  
  replicate = replicates,
  sample_size = sample_sizes
)) %>%
  purrr::pmap_dfr(~ process_one_replicate(..1, ..2, ..3))

saveRDS(all_results, file = "plots/supplementary/rds/sim_noise_allResults_v2.RDS")


## Generate data summary ##

all_results <- readRDS("plots/supplementary/rds/sim_noise_allResults_v2.RDS")

summary_stats <- all_results %>%
  group_by(noise_level, sample_size, group_clean) %>%
  summarise(
    mean_n_clean = round(mean(n_clean)),
    sd_n_clean = sd(n_clean),
    
    mean_n_noisy = round(mean(n_noisy)),
    sd_n_noisy = sd(n_noisy),
    
    mean_jaccard = mean(Jaccard_index),
    sd_jaccard = sd(Jaccard_index),
    
    mean_log2FC_corr = mean(log2FC_corr),
    sd_log2FC_corr = sd(log2FC_corr),
    
    mean_pval_corr = mean(pval_corr),
    sd_pval_corr = sd(pval_corr),
    
    .groups = "drop"
  )

summary_stats$noise_level <- factor(
  summary_stats$noise_level,
  levels = c("noise_10", "noise_15", "noise_20", "noise_25")
)

summary_stats$group_clean <- factor(summary_stats$group_clean, levels = c("DSG", "DCG", "DIG", "non_DEG"))

#write.xlsx(summary_stats, file = "results/simulation_performance/cn_noise_robustness/robustness_simulation_metrics.xlsx")
saveRDS(summary_stats, file = "plots/supplementary/rds/robustness_sim_metrics.rds")

# Plot

logFC_corr_plot <- plot_metrics_robustness(summary_stats, "log2FC_corr", "Mean log2FC Pearson corr (R²)")
jaccard_plot <- plot_metrics_robustness(summary_stats, "jaccard", "Mean Jaccard Index")
pval_corr <- plot_metrics_robustness(summary_stats, "pval_corr", "Mean FDR Spearman corr (R²)")

 combined_plot <- (jaccard_plot / logFC_corr_plot / pval_corr) +
  plot_annotation(
    tag_levels = 'A',
    tag_prefix = "",
    tag_suffix = "",
    theme = theme(
      plot.tag = element_text(face = "plain", size = 12, family = "")
    )
  )
combined_plot

ggsave("plots/figures/supplementary/S2_Fig.png", dpi = 500, width = 7.5, height = 8.0, plot = combined_plot)    
