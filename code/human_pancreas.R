#------------------------------------------------------SETUP-----------------------------------------------------#

# Load libraries
library(tidyverse)
library(data.table)
library(BuenColors)
library(Seurat)
library(irlba)
library(Matrix)
library(future)
library(reticulate)
library(ggrastr)
library(tidytext)
library(matrixTests)
source("utils.R")

# Set up parallelization
# Remember to use htop to delete forgotten forks
Sys.setenv(R_FUTURE_FORK_ENABLE = T)
options(future.globals.maxSize = 2048 * 1024^2)
plan(strategy = "multicore", workers = 32)

# Parameters
name <- "human_pancreas"
number_pcs <- 40
vargenes <- 3000
clus_res <- 1

# Setup
dir.create(paste0("../plots/", name))
dir.create(paste0("../features/", name))

# Notes on data:
# Authors DID NOT provide cell type / cluster IDs for cells
# Authors provided gene symbols, some are duplicated

#------------------------------------------------LOAD AND FORMAT DATA-----------------------------------------------#

# Read in data and annotations
file <- paste0("../data/", name, "/GSE85241_cellsystems_dataset_4donors_updated.csv.gz")
mat <- data.frame(fread(cmd = paste0("zcat < ", file), skip = 1, sep = "\t"))[,-1] %>%
  data.matrix() %>% 
  Matrix()
rownames(mat) <- data.frame(cmd = fread(paste0("zcat < ", file), select = 1, skip = 1, sep = "\t"))[,1] %>%
  gsub("__.*", "", .)
file <- paste0("../data/", name, "/cellnames.txt")
mat.annot <-  read_delim(file, delim = " ", col_names = c("cell", "donor", "library", "id")) %>% 
  data.frame()
row.names(mat.annot) <- mat.annot$cell
colnames(mat) <- mat.annot$cell

# Read in annotations
keep <- read.table("../resources/gene_annot_jun10.txt", sep = "\t", header = T, stringsAsFactors = F, col.names = c("ENSG", "symbol", "chr", "start", "end", "TSS"))

# Filter expression matrix
rowkeep <- row.names(mat) %in% keep$symbol
mat <- mat[rowkeep,]

# Deal with duplicate gene symbols
mat <- mat[!duplicated(row.names(mat)),]
dups <- keep %>%
  dplyr::filter(symbol %in% row.names(mat)) %>%
  count(symbol) %>%
  dplyr::filter(n > 1) %>%
  .$symbol
keep <- keep %>%
  group_by(symbol) %>%
  dplyr::mutate(size = abs(start - end),
                rank = rank(size))
matdups <- mat[dups,]
keepdups <- keep %>%
  dplyr::filter(rank == 2)
row.names(matdups) <- keepdups[match(row.names(matdups), keepdups$symbol),]$ENSG
keepnotdups <- keep %>%
  dplyr::filter(rank == 1)
row.names(mat) <- keepnotdups[match(row.names(mat), keepnotdups$symbol),]$ENSG
mat <- rbind(mat, matdups)

# Add missing genes as sparse rows
notkeep <- keep %>%
  dplyr::filter(ENSG %ni% row.names(mat))
missing <- sparseMatrix(dims = c(dim(notkeep)[1], length(colnames(mat))), i={}, j={})
row.names(missing) <- notkeep$ENSG
colnames(missing) <- colnames(mat)
mat <- rbind(mat, missing)

#--------------------------------------------------COMPUTE FEATURES-------------------------------------------------#

# Create Seurat object
# min.features determined for each dataset
so <- CreateSeuratObject(counts = mat, project = name, min.features = 200, meta.data = mat.annot)

# Clean up
rm(mat)

# QC
so <- subset(so, 
             subset = nFeature_RNA > quantile(so$nFeature_RNA, 0.05) & 
               nFeature_RNA < quantile(so$nFeature_RNA, 0.95))
so <- NormalizeData(so, normalization.method = "LogNormalize", scale.factor = 1000000)
so <- ScaleData(so, min.cells.to.block = 1, block.size = 500)

# Identify variable genes
so <- FindVariableFeatures(so, nfeatures = vargenes)
# Plot variable genes with and without labels
PlotAndSaveHVG(so, name)

# Run PCA
so <- RunPCA(so, npcs = 100)
# Project PCA to all genes
so <- ProjectDim(so, do.center = T)
# Plot Elbow
PlotAndSavePCAElbow(so, 100, name)

# Run ICA
so <- RunICA(so, nics = number_pcs)
# Project ICA to all genes
so <- ProjectDim(so, reduction = "ica", do.center = T)

# Cluster cells
so <- FindNeighbors(so, dims = 1:number_pcs, nn.eps = 0)
so <- FindClusters(so, resolution = clus_res, n.start = 100)

# UMAP dim reduction
so <- RunUMAP(so, dims = 1:number_pcs, min.dist = 0.4, n.epochs = 500,
              n.neighbors = 10, learning.rate = 0.1, spread = 2)

# Plot UMAP clusters
PlotAndSaveUMAPClusters(so, so@meta.data$seurat_clusters, name)

# Plot PCs on UMAP
PlotAndSavePCsOnUMAP(so, name)
# Plot ICs on UMAP
PlotAndSaveICsOnUMAP(so, name)
# Plot known marker genes on UMAP 
marker_genes <- c("GCG", "INS", "SST", "MAFA", "PPY", "PRSS1", "KRT19", "MAFB", "GSTA2", "GHRL", "ESAM")
PlotAndSaveKnownMarkerGenesOnUMAP(so, keep, marker_genes, name)

# Save global features
SaveGlobalFeatures(so, name)

# Compute any cluster dependent features (DE genes, within-cluster PCs, etc.) and save them
# Seurat clusters
Idents(object=so) <- "seurat_clusters"
clus <- levels(so@meta.data$seurat_clusters)
demarkers <- WithinClusterFeatures(so, "seurat_clusters", clus, name)

# Plot DE genes on UMAP
PlotAndSaveDEGenesOnUMAP(so, demarkers, name, height = 10, rank_by_tstat = TRUE)

# Save Seurat object
saveRDS(so, paste0("../data/", name, "/so.rds"))

