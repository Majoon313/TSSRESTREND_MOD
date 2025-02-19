# Title: TSS-RESTREND change detection and attribution demonstration
# Author: Arden Burrell

library(foreach)
library(xts)
library(zoo)
library(lubridate)
library(TSS.RESTREND)
library(jsonlite)
library(optparse)
# library(bfast)

# ========== Check if the relative paths are going to work ==========
cwd = getwd()
if (endsWith(cwd, "NCdemo")){
   # The folder is
}else if (file.exists(paste0(cwd, "/S02_TSSRESTRENDattribution.R"))){
   # pass as well. the folder has been renamed
}else{
   # pass
   if (dir.exists(paste0(cwd, "NCdemo"))){
      setwd("NCdemo")
  }else{
     stop("Script running in an unknown working directory. Please run from or set the working dir to the NCdemo folder ")
  }}



# ========== Pull in the option ==========
option_list = list(
   make_option(c("-i", "--infofile"), type="character", default='./results/infomation.json',
               help="the infomation file", metavar="character"),
   make_option(c("-n", "--ncores"), type = "integer", default = 0,
            help="The number of threads to use.  if -1, all cores used"))
opt_parser = OptionParser(option_list=option_list);
opt = parse_args(opt_parser);

# ========== If required setup a paralle backend ==========
ncores = opt$ncores

if (ncores == 0){
  par = FALSE
}else{
  par=TRUE
  # ========== Parallel packages ==========
  library(doSNOW)
  # +++++ Work out hte number of cores +++++
  if (ncores == -1){
    ncores <- parallel::detectCores()
  }
  print(paste("Number of cores:", ncores))
}
# ========== read in the vegetation and climate data ==========
fnVI <- "./data/demo_dataframe_ndvi.csv"
VIdf <- read.csv(fnVI, row.names=1, check.names=FALSE) # NDVI
fnPP <- "./data/demo_dataframe_ppt.csv"
PPdf <- read.csv(fnPP, row.names=1, check.names=FALSE) # precip
fnTM <- "./data/demo_dataframe_tmean.csv"
TMdf <- read.csv(fnTM, row.names=1, check.names=FALSE) # temperature
fnC4 <- "./data/demo_dataframe_C4frac.csv"
C4df <- read.csv(fnC4, row.names=1, check.names=FALSE) # C4 frac
C4df[C4df < 0] = 0.
C4df[C4df > 1] = 1.

fnIN <- opt$infofile
info <- fromJSON(fnIN)

# ========== pull out the info from the setup json =========
anres   <- info$annual
max.acp <- info$maxacp
max.osp <- info$maxosp

# ========= Create a function that can be used in foreach ==========
tssr.attr <- function(line, VI, PP, TM, C4frac, max.acp, max.osp, AnnualRes, par){
  # =========== Function is applied to one pixel at a time ===========
  # ========== Perfrom the data checks and if anything fails skipp processing ==========
  # There is a data check for NANs in the TSSRattribution function, If SkipError is True
  # It then returns an opject of the same structure as actual results but filled with NaN
  # Usefull stacking using the foreac::do command.
  if (any(is.na(VI)) | (sd(VI)==0)){
     results = TSSRattribution(c(NA, NA), c(NA, NA), c(NA, NA), max.acp, max.osp, AnnualRes=AnnualRes, 
      returnVCRcoef=FALSE,  SkipError=TRUE)
  }else if (any(is.na(PP))){
     results = TSSRattribution(c(1,1), c(NA, NA), c(NA, NA), max.acp, max.osp, AnnualRes=AnnualRes, 
      returnVCRcoef=FALSE,  SkipError=TRUE)
  }else if (any(is.na(TM))){
     results = TSSRattribution(c(1,1), c(1,1), c(NA, NA), max.acp, max.osp, AnnualRes=AnnualRes, 
      returnVCRcoef=FALSE,  SkipError=TRUE)
  }else{
    if (!par){print(line)}
    # ========== Deal with Dates ==========
    # +++++ COnvert the VI to a TS object +++++
    VIdates <- as.POSIXlt(colnames(VI))
    VIys    <- VIdates[1]$year + 1900
    VIms    <- month(VIdates[1])
    VIyf    <- tail(VIdates, n=1)$year+ 1900
    VImf    <- month(tail(VIdates, n=1))
    CTSR.VI <- ts(as.numeric(VI), start=c(VIys, VIms), end=c(VIyf,VImf), frequency = 12)

    # +++++ COnvert the PPT to a TS object +++++
    PPdates <- as.POSIXlt(colnames(PP))
    PPys    <- PPdates[1]$year + 1900
    PPms    <- month(PPdates[1])
    PPyf    <- tail(PPdates, n=1)$year+ 1900
    PPmf    <- month(tail(PPdates, n=1))
    CTSR.RF <- ts(as.numeric(PP), start=c(PPys, PPms), end=c(PPyf,PPmf), frequency = 12)

    # +++++ COnvert the tMANS to a TS object +++++
    TMdates <- as.POSIXlt(colnames(TM))
    TMys    <- TMdates[1]$year + 1900
    TMms    <- month(TMdates[1])
    TMyf    <- tail(TMdates, n=1)$year+ 1900
    TMmf    <- month(tail(TMdates, n=1))
    CTSR.TM <- ts(as.numeric(TM), start=c(TMys, TMms), end=c(TMyf,TMmf), frequency = 12)

    # ========== get the results ==========
    results = TSSRattribution(
      CTSR.VI, CTSR.RF, CTSR.TM, max.acp,
      max.osp, C4frac=round(C4frac, digits = 4),
      AnnualRes=AnnualRes, returnVCRcoef=TRUE, SkipError=TRUE)

    if (is.null(results)){
      browser()
    }
  }
  # ========== return the results ==========
  ret <- results$summary
  rownames(ret) <- line          # add the row name back
  ret["errors"] = results$errors # add the reason for failure
  return(ret)
}

# ========== Setup parallel processing ==========
if (par){
  print(paste("Starting parellel processing at:", Sys.time()))
  cl <- makeCluster(ncores)
  registerDoSNOW(cl)
  # Setup the progress bar
  pb <- txtProgressBar(max =dim(VIdf)[1], style = 3)
  progress <- function(n) setTxtProgressBar(pb, n)
  opts <- list(progress = progress)

  # ========== Loop over the rows in parallel ==========
  ptime  <- system.time(
    tss.atdf <- foreach(
      line=rownames(VIdf), .combine = rbind, .options.snow = opts,
      .packages = c('TSS.RESTREND', "xts", "lubridate")) %dopar% {
        tssr.attr(line, VIdf[line, ], PPdf[line,], TMdf[line,], C4df[line, ], max.acp, max.osp, anres, par)
      })
  print(paste("\n Parellel processing complete at:", Sys.time()))

} else{
  # ========== Loop over the rows sequentially ==========
  ptime  <- system.time(
    tss.atdf <- foreach(
      line=rownames(VIdf), .combine = rbind) %do% {
        tssr.attr(line, VIdf[line, ], PPdf[line,], TMdf[line,], C4df[line, ], max.acp, max.osp, anres, par)
      })
}


# ========== name to save the file ==========
fnout <- "./results/AttributionResults.csv"
write.csv(tss.atdf, fnout)

# ========== modify the info file ==========
info$ComputeTime = ptime[[1]]
info$TSSRESTREND.version = toString(packageVersion("TSS.RESTREND"))
info$history = paste(toString(Sys.time()), ": TSS.RESTREND change estimates calculated using S02_TSSRESTRENDattribution.R. ", info$history)

jinfo = toJSON(info, auto_unbox = TRUE, pretty=4)
write(jinfo, fnIN)
print(ptime)

# browser()

