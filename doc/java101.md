# Java Worker 101

## **Architecture Basics**

The Azure Functions host and the Java Worker follow a **server-client relationship**:

- The host sets up a **gRPC server** and launches the worker as a separate process with appropriate command-line options.
- The worker initializes a **gRPC client** that connects to the host, enabling bi-directional communication.

The worker processes various request types based on its lifecycle:

1. **Initialization Phase**:
    - `WORKER_INIT_REQUEST` (once): Sends metadata to configure the worker environment, including the worker’s version, supported features, and runtime-specific properties.
    - `WORKER_WARMUP_REQUEST` (once): Optimizes performance-critical code paths.
    - `FUNCTION_ENVIRONMENT_RELOAD_REQUEST` (once): Applies environment variables required by customer functions.
    - `FUNCTION_LOAD_REQUEST` (many): Loads customer-defined functions.

2. **Execution Phase**:
    - `INVOCATION_REQUEST` (many): Executes customer functions.
    - `WORKER_STATUS_REQUEST` (many): Reports worker health and status.

3. **Shutdown Phase**:
    - `WORKER_TERMINATE` (once): Gracefully shuts down the worker.

Each request type is handled by a specific implementation of the `MessageHandler` abstract class. The worker can process multiple requests concurrently, with each request being processed on a separate thread.

---

## **Worker Startup**

When the Java Worker starts, the host launches the worker JAR file with command-line options specifying the gRPC server details. The worker’s entry point, the `Application` class, parses these arguments and invokes its `main` method.

### **Startup Workflow**

1. **Initialize Core Components**:
    - Establishes a gRPC connection to listen for requests.
    - Registers request handlers for various message types.
    - Sets up a `ClassLoaderProvider` using a factory.
    - Prepares core components for managing function loading and execution.

2. **Class Loader Provider**:
    - If the worker runs on **Java 8**, it uses the `DefaultClassLoaderProvider`, which relies on the JVM’s system class loader.
    - For **Java 11 or later**, it uses the `EnhancedClassLoaderProvider`, which creates a custom class loader. This isolates customer function classes from the worker, improving security and efficiency.

### **Shading**

Shading is a critical mechanism in the worker that avoids dependency conflicts between the worker’s internal libraries and customer function dependencies.

#### **What Is Shading?**

Shading repackages dependencies into a private namespace, ensuring that:

- Worker dependencies are isolated from customer functions.
- Version conflicts are avoided for common libraries.

#### **Implementation Details**

- Worker dependencies are shaded into the `com.microsoft.azure.shaded` namespace.
- The shading process is configured using the Maven Shade Plugin in the `pom.xml` file:

  ```xml
  <relocation>
      <pattern>com.google.protobuf</pattern>
      <shadedPattern>com.microsoft.azure.shaded.com.google.protobuf</shadedPattern>
  </relocation>
  ```

If a dependency is not shaded, **the** worker’s version takes precedence since it is loaded first by the system class loader.

### **Java Function Broker**

The `JavaFunctionBroker` is a core component of the worker, responsible for managing customer functions throughout their lifecycle. It serves as a bridge between the host and the Java runtime by:

1. **Loading Functions**:
    - Discovers and validates function metadata provided by the host (e.g., function name, ID, JAR path).
    - Loads the classpath for each function into the class loader.

2. **Resolving Functions**:
    - Matches incoming invocation requests to the correct Java function.

3. **Executing Functions**:
    - Invokes the function using input data provided by the host and returns the results.

The `JavaFunctionBroker` is thread-safe, allowing multiple functions to be loaded and executed concurrently.

---

## **Worker Initialization**

### **Initialization Process**

After the worker establishes communication with the host, it processes a `WORKER_INIT_REQUEST` message containing the working directory and metadata for the worker. During this process:

- The worker configures its working directory.
- Metadata is sent to the host, including:
    - Runtime name and version.
    - Worker version.
    - Supported features.

Next, the host sends a `WORKER_WARMUP_REQUEST` message to optimize performance-critical code paths. This involves:

- Using a built-in HTTP trigger function for warming up:
    - Worker specialization logic.
    - Function loading and invocation paths.

These steps ensure that critical code paths are precompiled by the JVM, eliminating delays during customer function execution.

---

## **Function Initialization**

### **Function Initialization Workflow**

Once the worker is initialized, the host specializes it for specific customer functions by:

1. Sending a `FUNCTION_ENVIRONMENT_RELOAD_REQUEST` message containing environment variables for the function.
    - These variables are applied by the worker.
    - If updates are required, the host restarts the worker.

2. Sending one or more `FUNCTION_LOAD_REQUEST` messages, one for each `function.json` found in the customer’s function deployment package.

During the handling of a `FUNCTION_LOAD_REQUEST`, the worker:

- Validates function metadata (e.g., function name, ID, and JAR path).
- Loads the function classpath into the class loader.
- Executes one-time initialization logic to prepare the function for execution.

### **One-Time Initialization Logic**

The `JavaFunctionBroker` ensures that certain operations are performed only once, even in a multi-threaded environment. These include:

#### **Invocation Chain Factory**

- Initializes the `InvocationChainFactory`, which manages a pipeline of middleware used during function invocation.
- Middleware includes:
    - Customer-provided `Middleware` implementations (discovered using `ServiceLoader`).
    - The `FunctionExecutionMiddleware`, which handles the actual execution of functions.

#### **Function Instance Injector**

The injector facilitates integration with dependency injection (DI) frameworks (e.g., Spring, Quarkus). This enables dependencies (e.g., services, configurations) to be injected into function classes, improving modularity and testability.

- Sets up a `FunctionInstanceInjector` to manage the lifecycle of function instances.
- If no custom injector is found using `ServiceLoader`, the broker defaults to creating a new instance of the function class for each invocation.

#### **Thread Safety**

- Initialization logic is synchronized to prevent race conditions and ensure consistency across threads.

---

## **Function Invocation**

The handling of the `INVOCATION_REQUEST` message involves invoking the correct Java function based on the request data, processing the invocation chain, and returning the result to the host.

### **Execution Workflow**

1. **Building the Execution Context**:

    - The worker builds an `ExecutionContextDataSource` for the function.

2. **Processing the Invocation Chain**:

    - The invocation chain processes the execution context through each middleware component. The final middleware in the chain, the `FunctionExecutionMiddleware`, invokes the Java function using the execution context.

3. **Returning the Result**:

    - After execution, the invocation result is captured from the `ExecutionContextDataSource` and sent back to the host as part of the `InvocationResponse`.

### **ExecutionContextDataSource**

A central object used to:

- Manage input and output data during function invocation using the `BindingDataStore`.
- Provide execution trace and retry contexts.
- Store the invocation result.

### **Invocation Chain**

The **Invocation Chain** is a sequence of middleware that applies pre-invocation logic (e.g., validation), executes the function, and handles post-invocation tasks (e.g., cleanup). It is created by the `InvocationChainFactory`.

### **Function Execution Middleware**

This is the final middleware in the chain and is responsible for invoking the actual Java method representing the function. It uses:

- The `ParameterResolver` to resolve the parameters to the types that the
  function expects.
- The `JavaMethodExecutor` to execute the function.
- The `FunctionInstanceInjector` to create or reuse the function instance.

#### **Input Conversion**

The worker uses the following steps to convert input data from raw formats into Java types for function invocation:

1. **Input Retrieval**:
    - Data arrives in the `TypedData` format, encapsulating types like strings, JSON, byte arrays, and more.
    - The `BindingDataStore` retrieves the appropriate `TypedData` for each function parameter.

2. **Type Resolution**:
    - The `CoreTypeResolver` determines the Java type required by the function parameter.
    - Reflection is used to cast the raw data into the resolved type.

3. **Examples**:
    - A string is converted into a `UUID` if the parameter type is `java.util.UUID`.
    - JSON strings are deserialized into `Map` objects or custom POJOs.

4. **Error Handling**:
    - If the conversion fails (e.g., type mismatch or unsupported type), an exception is thrown, and an error response is sent to the host.

#### **Output Conversion**

The worker transforms Java return types and output bindings back into formats compatible with the host:

1. **Serialization**:
    - Primitives and built-in types are directly converted into strings or compatible formats.
    - For custom objects, serialization logic (e.g., JSON serialization) is applied.
    - If a custom object cannot be serialized, the worker throws an exception, and an error response is sent to the host.

2. **Response Construction**:
    - Serialized data is packaged into a `TypedData` object.
    - The `InvocationResponse` includes these serialized outputs, sent back to the host.