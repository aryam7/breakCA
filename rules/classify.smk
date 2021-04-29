from snakemake.utils import min_version

##### set minimum snakemake version #####
min_version("5.18.0")

if 'imported' not in config:
    configfile: "configs/classify.yaml"

container: "docker://continuumio/miniconda3:4.8.2"


def check_config(value, default=False, place=config):
    """ return true if config value exists and is true """
    return place[value] if (value in place and place[value]) else default

config['out'] = check_config('out', 'out/classify')

if not hasattr(rules, 'all'):
    rule all:
        input:
            expand(
                config['out']+"/{sample}/final.vcf.gz",
                sample=[
                    s for s in config['predict']
                    if check_config('merged', place=config['data'][s])
                ]
            ) + expand(
                config['out']+"/{sample}/prc/results.pdf",
                sample=[
                    s for s in config['predict']
                    if check_config('truth', place=config['data'][s])
                ] if 'prcols' in config and isinstance(config['prcols'], dict) else []
            ) + expand(
                config['out']+"/{sample}/tune.pdf",
                sample=config['train'] if check_config('tune') and not check_config('model') else []
            )

rule subset_callers:
    """ take a subset of the callers for each dataset """
    input: lambda wildcards: config['data'][wildcards.sample]['path']
    params:
        callers = lambda wildcards: "|".join(config['subset_callers'])
    output: config['out']+"/{sample}/subset.tsv.gz"
    conda: "../envs/classify.yml"
    shell:
        "zcat {input} | scripts/cgrep.bash - -E '^(CHROM|POS|REF)$|^({params.callers})~' | gzip > {output}"

rule filters:
    """ apply filtering on the data according to the filtering expressions """
    input: lambda wildcards: rules.subset_callers.output if check_config('subset_callers') else config['data'][wildcards.sample]['path']
    params:
        expr = lambda wildcards: config['data'][wildcards.sample]['filter']
    output: config['out']+"/{sample}/filter.tsv.gz"
    conda: "../envs/classify.yml"
    shell:
        "zcat {input} | scripts/filter.bash {params.expr:q} | gzip > {output}"


def prepared_data(wildcards):
    """ return the path to the prepared data """
    if check_config('filter', place=config['data'][wildcards.sample]):
        return rules.filters.output
    if check_config('subset_callers'):
        return rules.subset_callers.output
    return config['data'][wildcards.sample]['path']


rule annotate:
    """ create a table of annotations at each site """
    input: prepared_data
    output: temp(config['out']+"/{sample}/annot.tsv.gz")
    conda: "../envs/classify.yml"
    shell:
        "zcat {input} | scripts/cgrep.bash - -E '^CHROM$|^POS$|~CLASS:' | gzip > {output}"

rule add_truth:
    """
        Add labels from all callers as the last columns in the training data
        Also ensure that if a true label is available for this dataset, it appears
        as the very last column
    """
    input:
        tsv = prepared_data,
        annot = rules.annotate.output
    params:
        truth = lambda wildcards: '^'+config['data'][wildcards.sample]['truth']+"~" if check_config('truth', place=config['data'][wildcards.sample]) else ""
    output: config['out']+"/{sample}/prepared.tsv.gz"
    conda: "../envs/classify.yml"
    shell:
        "paste "
        "<(zcat {input.annot} | cut -f 3- | scripts/cgrep.bash - -v '{params.truth}') "
        "<(zcat {input.annot} | cut -f 3- | scripts/cgrep.bash - '{params.truth}') | "
        "sed 's/^\\t//' | paste <(zcat {input.tsv} | "
        "scripts/cgrep.bash - -v '~CLASS:' | "
        "scripts/cgrep.bash - -Evx '(CHROM|POS|REF)') - | gzip > {output}"


def train_output():
    """ return the output to the train rule, conditional on the tune config param """
    output = [config['out']+"/{sample}/model.rda", config['out']+"/{sample}/variable_importance.tsv"]
    if check_config('tune'):
        output.append(config['out']+"/{sample}/tune_matrix.tsv")
    return output


rule train:
    """ train the classifier """
    input: rules.add_truth.output
    params:
        balance = int(config['balance']) if 'balance' in config else 0
    output: train_output()
    conda: "../envs/classify.yml"
    shell:
        "Rscript scripts/train_RF.R {input} {params.balance} {output}"

rule plot_tune:
    """ plot the results of the hyperparameter tuning step """
    input: config['out']+"{sample}/tune_matrix.tsv"
    output: config['out']+"{sample}/tune.pdf"
    conda: "../envs/classify.yml"
    shell:
        "Rscript scripts/tune_plot.R {input} {output}"

def get_model_for_sample(wildcards):
    """ get the appropriate model for the specified sample """
    if check_config('model', place=config['data'][wildcards.sample]):
        return config['data'][wildcards.sample]['model']
    return config['model'] if check_config('model') else expand(
        rules.train.output[0], sample=config['train']
    )

rule predict:
    """ predict variants using the classifier """
    input:
        model = get_model_for_sample,
        predict = lambda wildcards: expand(rules.add_truth.output, sample=wildcards.sample)
    conda: "../envs/classify.yml"
    output: temp(config['out']+"/{sample}/predictions.tsv")
    shell:
        "Rscript scripts/predict_RF.R {input.predict} {input.model} {output}"

rule results:
    """
        join the predictions with the annotations
        also prefix the colnames of our method before merging
    """
    input:
        predict = rules.predict.output,
        annot = rules.annotate.output
    params:
        truth = lambda wildcards: config['data'][wildcards.sample]['truth'] if check_config('truth', place=config['data'][wildcards.sample]) else ""
    output: config['out']+"/{sample}/results.tsv.gz"
    conda: "../envs/classify.yml"
    shell:
        "cat {input.predict} | paste <(zcat {input.annot}) "
        "<(read -r head && echo \"$head\" | tr '\\t' '\\n' | "
        "sed 's/response/CLASS:/' | sed 's/^/varca~/' | "
        "paste -s && cat) | gzip > {output}"


def sort_col(caller):
    if caller in config['prcols']:
        return config['prcols'][caller], False
    elif "*"+caller in config['prcols']:
        return config['prcols']["*"+caller], True
    else:
        return "", False


rule prc_pts:
    """ generate single point precision recall metrics """
    input:
        results = rules.results.output,
        predicts = lambda wildcards: rules.results.output if wildcards.caller == 'varca' else prepared_data(wildcards)
    params:
        truth = lambda wildcards: config['data'][wildcards.sample]['truth'] if check_config('truth', place=config['data'][wildcards.sample]) else "",
        predict_col = lambda wildcards: 'prob.1' if wildcards.caller == 'varca' else sort_col(wildcards.caller)[0],
        ignore_probs = lambda wildcards: "" if wildcards.caller == 'varca' or sort_col(wildcards.caller)[0] else "--ignore-probs",
        flip = lambda wildcards: ["", "-f"][sort_col(wildcards.caller)[1]]
    output: config['out']+"/{sample}/prc/pts/{caller}.txt"
    conda: "../envs/prc.yml"
    shell:
        "paste "
        "<(zcat {input.results} | scripts/cgrep.bash - '{params.truth}~CLASS:') "
        "<(zcat {input.results} | scripts/cgrep.bash - '{wildcards.caller}~CLASS:') "
        "<(zcat {input.predicts} | scripts/cgrep.bash - -F '{wildcards.caller}~{params.predict_col}')"
        " | tail -n+2 | scripts/metrics.py -o {output} {params.ignore_probs} {params.flip}"

rule prc_curves:
    """ generate the points for a precision recall curve """
    input:
        annot = rules.annotate.output,
        predicts = lambda wildcards: rules.results.output if wildcards.caller == 'varca' else prepared_data(wildcards)
    params:
        truth = lambda wildcards: config['data'][wildcards.sample]['truth'] if check_config('truth', place=config['data'][wildcards.sample]) else "",
        predict_col = lambda wildcards: 'prob.1' if wildcards.caller == 'varca' else sort_col(wildcards.caller)[0],
        flip = lambda wildcards: ["", "-f"][sort_col(wildcards.caller)[1]],
        thresh = lambda wildcards: "-t" if wildcards.caller == 'varca' else ""
    output: config['out']+"/{sample}/prc/curves/{caller}.txt"
    conda: "../envs/prc.yml"
    shell:
        "paste "
        "<(zcat {input.annot} | scripts/cgrep.bash - '{params.truth}~CLASS:') "
        "<(zcat {input.predicts} | scripts/cgrep.bash - -F '{wildcards.caller}~{params.predict_col}') | "
        "tail -n+2 | scripts/statistics.py -o {output} {params.flip} {params.thresh}"


def sort_cols(strict=False):
    return [
        caller[caller.startswith("*") and len("*"):]
        for caller in config['prcols'].keys()
        if not strict or config['prcols'][caller]
    ]


rule prc:
    """ create plot containing precision recall curves """
    input:
        pts = lambda wildcards: expand(
            rules.prc_pts.output, sample=wildcards.sample,
            caller=['varca']+sort_cols()
        ),
        curves = lambda wildcards: expand(
            rules.prc_curves.output, sample=wildcards.sample,
            caller=['varca']+sort_cols(True)
        )
    params:
        pts = lambda _, input: [k for j in zip(['--'+i+"_pt" for i in ['varca']+sort_cols()], input.pts) for k in j],
        curves = lambda _, input: [k for j in zip(['--'+i for i in ['varca']+sort_cols(True)], input.curves) for k in j]
    output: config['out']+"/{sample}/prc/results.pdf"
    conda: "../envs/prc.yml"
    shell:
        "scripts/prc.py {output} {params.pts} {params.curves}"

rule tsv2vcf:
    """ convert results.tsv.gz to vcf using merge.tsv.gz """
    input:
        merge = lambda wildcards: config['data'][wildcards.sample]['merged'],
        results = rules.results.output
    params:
        callers = "-c '"+",".join(config['callers'])+"'" if check_config('callers') else ""
    output: temp(config['out']+"/{sample}/results.vcf.gz")
    conda: "../envs/prc.yml"
    shell:
        "zcat {input.merge} | scripts/cgrep.bash - -E '^(CHROM|POS|REF)$|.*~(REF|ALT)$' | scripts/2vcf.py -o {output} {params.callers} {input.results} || true"

rule fix_vcf_header:
    """ add contigs to the header of the vcf """
    input:
        genome = config['genome']+".fai",
        vcf = rules.tsv2vcf.output
    output: config['out']+"/{sample}/final.vcf.gz"
    conda: "../envs/prc.yml"
    shell:
        "bcftools reheader -f {input.genome} {input.vcf} -o {output}"
