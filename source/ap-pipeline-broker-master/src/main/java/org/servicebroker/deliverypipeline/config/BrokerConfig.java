package org.servicebroker.deliverypipeline.config;

import org.springframework.boot.autoconfigure.domain.EntityScan;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;


/**
 * Force the base spring boot packages to be searched for dependencies.
 *
 * @author sgreenberg
 *
 */

@Configuration
@EnableJpaRepositories("org.servicebroker.deliverypipeline.repo")
@EntityScan(value = "org.servicebroker.deliverypipeline.model")
@ComponentScan(basePackages = { "org.servicebroker", "org.openpaas.servicebroker"})
public class BrokerConfig {
}
