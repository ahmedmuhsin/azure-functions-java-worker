package com.microsoft.azure.functions.worker.broker;

import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.List;
import java.util.stream.Collectors;

public final class MethodBindInfo {

    private final Method method;
    private final List<ParamBindInfo> params;
    private final boolean hasImplicitOutput;
    MethodBindInfo(Method method) {
        this.method = method;
        this.params = Arrays.stream(method.getParameters()).map(ParamBindInfo::new).collect(Collectors.toList());
        this.hasImplicitOutput = checkImplicitOutput(params);
    }

    private static boolean checkImplicitOutput(List<ParamBindInfo> params){
        return params.stream().anyMatch(ParamBindInfo::isImplicitOutput);
    }

    public Method getMethod() {
        return method;
    }

    public List<ParamBindInfo> getParams() {
        return params;
    }

    public boolean hasEffectiveReturnType(){
        // For function annotated with @HasImplicitOutput, we should allow it to send back data even function's return type is void
        // Reference to https://github.com/microsoft/durabletask-java/issues/126
        return this.hasNonVoidReturnType() || this.hasImplicitOutput();
    }

    public boolean hasImplicitOutput() {
        return hasImplicitOutput;
    }

    public boolean hasNonVoidReturnType() {
        Class<?> returnType = this.method.getReturnType();
        return !returnType.equals(void.class) && !returnType.equals(Void.class);
    }
}


